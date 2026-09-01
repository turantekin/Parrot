import SwiftUI
import SwiftData
import CoreGraphics
import AVFoundation

/// Orchestrates audio capture, transcription, and storage for a recording session.
@MainActor
@Observable
final class RecordingManager {
    let audioCaptureManager = AudioCaptureManager()
    let transcriptionEngine = TranscriptionEngine()
    let diarizationEngine = DiarizationEngine()
    // Routes to Claude / Ollama / a custom server per Settings → Copilot.
    let callAnalysisEngine = CallAnalysisEngine(provider: SwitchingAnalysisProvider())
    let knowledgeBase = KnowledgeBaseService()
    let profileStore = ProfileStore()

    /// Optional one-line context for the next call, set from the dashboard.
    var nextCallBrief = ""

    private(set) var isRecording = false
    private(set) var recordingStartTime: Date?
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var currentMeeting: Meeting?

    /// Guards against a second startRecording slipping in during the `await`s
    /// before isRecording is set — which would start a duplicate transcription
    /// loop and double every segment.
    private var isStarting = false
    /// Mirror of isStarting for the stop path: stop now drains the transcription
    /// backlog (seconds, not instant), so without this a double-stop would persist
    /// insights twice and run postProcess twice, and a start-during-stop would
    /// cancel the draining loop and share buffers with the old session. Readable
    /// so the live view can show a "Finalizing…" state.
    private(set) var isStopping = false
    private var timer: Timer?
    private var modelContext: ModelContext?

    /// Set when a SwiftData save throws — shown in the live device bar.
    private(set) var persistenceNotice: String?
    let hybridRefiner = HybridRefiner()
    let translationStore = TranslationStore()
    let dictation = DictationController()
    let transforms = TransformController()
    /// Live call started from the Translate screen — language is the product.
    var translationSession = false
    /// Meeting whose post-call transcript translation is running.
    private(set) var translatingMeetingID: UUID?
    var transcriptTranslateNotice: String?

    /// Non-nil while a file import runs — drives the import banner in the UI.
    private(set) var importProgress: ImportProgress?

    struct ImportProgress: Equatable {
        var fileName: String
        var phase: Phase
        enum Phase {
            case transcribing, analyzing
            var label: String {
                switch self {
                case .transcribing: "Transcribing…"
                case .analyzing: "Analyzing…"
                }
            }
        }
    }

    init() {
        callAnalysisEngine.knowledgeBase = knowledgeBase
    }

    /// Dev-harness only (--help-shots): seed a live-looking session so
    /// LiveRecordingView can render offscreen without recording anything.
    func seedForSnapshot(meeting: Meeting, elapsed: TimeInterval, modelContext: ModelContext) {
        self.modelContext = modelContext
        currentMeeting = meeting
        elapsedTime = elapsed
        recordingStartTime = Date().addingTimeInterval(-elapsed)
        isRecording = true
    }

    /// Initialize and load the default WhisperKit model
    func prepare(modelContext: ModelContext) async {
        FeatureProcessing.migrateIfNeeded()
        self.modelContext = modelContext
        recoverInterruptedRecordings(in: modelContext)
        profileStore.seedAndMigrateIfNeeded(context: modelContext, knowledgeBase: knowledgeBase)
        await transcriptionEngine.loadModel(
            UserDefaults.standard.string(forKey: "whisperModel") ?? "base"
        )
        dictation.modelContext = modelContext
        dictation.isCallRecording = { [weak self] in self?.isRecording == true }
        dictation.transcribeLocal = { [weak self] url in
            guard let self else { return "" }
            let results = try await self.transcriptionEngine.transcribeFile(url: url)
            return results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        HotkeyCenter.shared.onDictation = { [weak self] in self?.dictation.toggleHandsFree() }
        HotkeyCenter.shared.onDictationHoldStart = { [weak self] in self?.dictation.beginHold() }
        HotkeyCenter.shared.onDictationHoldEnd = { [weak self] in self?.dictation.endHold() }
        HotkeyCenter.shared.onPasteLast = { [weak self] in self?.dictation.pasteLast() }
        HotkeyCenter.shared.onTransformLocal = { [weak self] in
            self?.transforms.run(destination: .local)
        }
        HotkeyCenter.shared.onTransformCloud = { [weak self] in
            self?.transforms.run(destination: .cloud)
        }
        HotkeyCenter.shared.start()
    }

    func beginTranslationSession() {
        translationSession = true
        translationStore.forced = true
        UserDefaults.standard.set(LiveSideTab.translation.rawValue, forKey: "liveSideTab")
        refreshWhisperTranslate()
        LocalTextModel.preloadForLocalTranslation()
    }

    func cancelTranslationSession() {
        translationSession = false
        translationStore.forced = false
        refreshWhisperTranslate()
        LocalTextModel.unloadAfterLocalTranslation()
    }

    func setTranslationTarget(_ code: String, segments: [TranscriptSegment] = []) {
        translationStore.setTarget(code, segments: segments)
        refreshWhisperTranslate()
    }

    func refreshWhisperTranslate() {
        transcriptionEngine.whisperTranslateEnabled =
            translationStore.isEnabled
            && FeatureProcessing.translation.runsLocalModel
            && LocalTranslation.whisperTranslatesToEnglish(translationStore.target)
    }

    /// A meeting left in `.recording` or `.processing` means the previous session was
    /// killed (crash or force-quit) before it could finish. The live transcript is
    /// already durable — `addSegment` saves every segment as it lands — so instead of
    /// discarding these, salvage the ones that captured any speech: re-run the normal
    /// post-call chain (diarization + report) on the surviving transcript and present
    /// them as recovered. Only truly empty orphans (killed before a word) stay failed.
    ///
    /// Runs at launch, off WhisperKit (transcript exists, diarization is energy-based,
    /// the report is a cloud call), so it needn't wait for the model.
    private func recoverInterruptedRecordings(in context: ModelContext) {
        guard let meetings = try? context.fetch(FetchDescriptor<Meeting>()) else { return }
        var changed = false
        for meeting in meetings where meeting.status == .recording || meeting.status == .processing {
            if meeting.segments.isEmpty {
                // Nothing was captured — the audio was never finalized and there's no
                // transcript to keep. Fail it, as before.
                meeting.status = .failed
                if meeting.errorMessage == nil {
                    meeting.errorMessage = "Recording was interrupted before it finished."
                }
            } else {
                // Salvageable: finish it in the background like a just-stopped call.
                meeting.wasRecovered = true
                meeting.status = .processing
                if meeting.duration == 0 {
                    meeting.duration = meeting.sortedSegments.last?.endTime ?? 0
                }
                let ref = meeting
                Task { await self.finishRecovery(meeting: ref) }
            }
            changed = true
        }
        if changed { try? context.save() }
    }

    private func finishRecovery(meeting: Meeting) async {
        // Audio is best-effort: a crash leaves the .caf header unfinalized, so it may
        // not open. If it doesn't, drop the paths so no dead player shows and
        // diarization is skipped cleanly (segments keep their live "Me"/"Them" labels).
        if let path = meeting.systemAudioPath.nilIfEmpty,
           (try? AVAudioFile(forReading: URL(fileURLWithPath: path))) == nil {
            meeting.systemAudioPath = ""
            meeting.micAudioPath = nil
            try? modelContext?.save()
        }

        // Same chain a clean stop runs: diarization refines speakers and sets .done;
        // the report runs when the copilot is configured. Coaching stays on — a
        // crashed live call still has a real per-segment "Me"/"Them" split.
        await postProcess(meeting: meeting)
        if callAnalysisEngine.isEnabled, callAnalysisEngine.provider.isConfigured,
           meeting.summary == nil {
            callAnalysisEngine.provider.resetUsage()
            await generateSummary(meeting: meeting)
        }
        writeAIUsage(meeting: meeting, polishSeconds: 0)
        meeting.status = .done
        try? modelContext?.save()
    }

    // MARK: - Recording Control

    /// The one shared entry point for every "start recording" button — checks
    /// permissions, then starts. Returns without starting (and without throwing)
    /// when a permission flow was triggered instead.
    func preflightPermissionsAndStart(modelContext: ModelContext) async throws {
        // Check the system-audio permission BEFORE touching any capture API.
        // macOS 15+: the audio-only tap permission (optimistic after the one
        // official prompt — its grant can't be read back, see PermissionFlow).
        // macOS 14: Screen Recording, where querying SCShareableContent while
        // unauthorized pops the OS prompt AND throws. Either way PermissionFlow
        // posts a single prompt or deep-links to Settings — never both.
        if #available(macOS 15.0, *) {
            // .promptShown proceeds too: the recording starts while the one-time
            // OS prompt hovers, and the silent-tap rescue picks the grant up
            // within ~15 s of Allow. Blocking would ransom the meeting to a
            // dialog for a grant we can't even read back. Only .openSettings
            // (asked before, still never proven) pauses to point at the pane.
            guard PermissionFlow.requestSystemAudioCapture() != .openSettings else { return }
        } else {
            guard PermissionFlow.requestScreenCapture() == .granted else { return }
        }

        // Ensure the microphone is authorized so the user's own voice ("Me")
        // is captured. Without this the engine runs but feeds silence.
        // Non-fatal: system audio still records if denied.
        _ = await PermissionFlow.requestMicrophone()

        try await startRecording(modelContext: modelContext)
    }

    func startRecording(modelContext: ModelContext) async throws {
        self.modelContext = modelContext
        // Reject re-entry up front (before any await) so a double-trigger can't
        // start two recordings / two transcription loops. Also blocked while a
        // file import is running — both drive the same shared WhisperKit.
        guard !isRecording, !isStarting, !isStopping, importProgress == nil else { return }
        guard transcriptionEngine.isReady else {
            throw RecordingError.modelNotReady
        }
        isStarting = true
        defer { isStarting = false }

        // Create meeting
        let meeting = Meeting()
        if translationSession {
            meeting.isTranslationRecording = true
            meeting.translationTargetCode = translationStore.target
        }
        modelContext.insert(meeting)

        // Persist active profile/brief/snapshot onto the meeting
        let profile = profileStore.activeProfile
        meeting.profile = profile
        meeting.brief = nextCallBrief.nilIfEmpty
        meeting.profileSnapshotData = profile.flatMap { try? JSONEncoder().encode($0.kinds) }

        // Set up audio capture. On failure, remove the just-inserted meeting —
        // otherwise it lingers as a ghost .recording row until the next launch's
        // orphan reconciliation flags it "interrupted".
        do {
            try await audioCaptureManager.startCapture()
        } catch {
            modelContext.delete(meeting)
            try? modelContext.save()
            throw error
        }
        meeting.systemAudioPath = audioCaptureManager.systemAudioURL?.path ?? ""
        meeting.micAudioPath = audioCaptureManager.micAudioURL?.path

        // Wire audio to transcription, tagged by stream (mic = Me, system = Them)
        audioCaptureManager.onAudioBuffer = { [weak self] buffer, source in
            self?.transcriptionEngine.appendAudio(buffer, source: source)
        }

        // A mid-call input-device change (dead AirPods, manual switch) rebuilds
        // the mic tap; the "Me" stream's clock must skip the dead gap or its
        // next locally-transcribed segments land minutes early.
        audioCaptureManager.onMicRestarted = { [weak self] in
            self?.transcriptionEngine.reanchorLocalClock(source: .me)
        }

        // Wire transcription output to storage and the live copilot
        transcriptionEngine.onSegment = { [weak self] result in
            Task { @MainActor in
                self?.addSegment(result)
                self?.callAnalysisEngine.ingest(
                    text: result.text,
                    at: result.endTime,
                    source: result.source
                )
            }
        }

        // Start transcription and the copilot loop
        refreshWhisperTranslate()
        transcriptionEngine.startTranscribing(meetingStartTime: .now)
        callAnalysisEngine.provider.resetUsage()  // this call's token meter starts at zero
        callAnalysisEngine.translationContext = { [weak self] in
            guard let self else { return nil }
            return TranslationContext.active(
                session: self.translationSession,
                enabled: self.translationStore.isEnabled,
                languageName: self.translationStore.targetLanguageName(),
                languageCode: self.translationStore.target)
        }
        callAnalysisEngine.start(profile: profile, brief: nextCallBrief)

        currentMeeting = meeting
        recordingStartTime = .now
        isRecording = true

        // Start elapsed time timer
        hybridRefiner.reset()
        translationStore.reset()
        persistenceNotice = nil
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartTime else { return }
                self.elapsedTime = Date.now.timeIntervalSince(start)
                if let meeting = self.currentMeeting {
                    self.hybridRefiner.tick(elapsed: self.elapsedTime, meeting: meeting, context: self.modelContext)
                }
            }
        }

        _ = saveContext(modelContext)
    }

    func stopRecording() async {
        guard isRecording, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        timer?.invalidate()
        timer = nil

        // Stop the copilot (its ingest no-ops once inactive), then capture — so
        // the transcription buffers stop growing and the drain below terminates.
        // Capture stops first also so both .caf files are finalized before the
        // diarization task can read them.
        callAnalysisEngine.stop()
        await audioCaptureManager.stopCapture()

        // Drain the transcription backlog so the call's final words land before
        // the transcript is assembled for the summary/coaching reports.
        await transcriptionEngine.stopTranscribing()
        // onSegment persists segments via Task { @MainActor } hops; yield once so
        // the last enqueued addSegment jobs run before we read segments back.
        await Task.yield()
        if let meeting = currentMeeting {
            await hybridRefiner.flush(meeting: meeting, elapsed: elapsedTime, context: modelContext)
        }

        // Update meeting
        if let meeting = currentMeeting {
            meeting.duration = elapsedTime
            meeting.status = .processing

            // Persist the copilot's insights so they survive into the meeting report.
            // Same SwiftData rule as addSegment: insert before setting the relationship.
            for insight in callAnalysisEngine.insights {
                let stored = CallInsight(from: insight)
                modelContext?.insert(stored)
                stored.meeting = meeting
            }
            try? modelContext?.save()

            // Post-processing chain, strictly sequential: polish rebuilds the
            // transcript (optional, best-effort), diarization refines labels on
            // whatever transcript survived, and the report is generated from
            // the FINAL text — never from a transcript that's about to change.
            let meetingRef = meeting
            let reportTranslation = TranslationContext.active(
                session: translationSession,
                enabled: translationStore.isEnabled,
                languageName: translationStore.targetLanguageName(),
                languageCode: translationStore.target)
            let liveTranslations = translationStore.lines
            let translationTarget = translationStore.target
            let wasTranslating = translationSession || translationStore.isEnabled
            Task {
                let polishSeconds = await self.polishTranscript(meeting: meetingRef)
                self.persistTranslations(liveTranslations, onto: meetingRef)
                if wasTranslating {
                    meetingRef.isTranslationRecording = true
                    if meetingRef.translationTargetCode.isEmpty {
                        meetingRef.translationTargetCode = translationTarget
                    }
                    await self.translateTranscript(meeting: meetingRef)
                } else {
                    LocalTextModel.unloadAfterLocalTranslation()
                }
                await self.postProcess(meeting: meetingRef)
                if self.callAnalysisEngine.isEnabled, self.callAnalysisEngine.provider.isConfigured {
                    await self.generateSummary(meeting: meetingRef, translation: reportTranslation)
                }
                // Last in the chain so the meter has seen the summary/coaching calls too.
                self.writeAIUsage(meeting: meetingRef, polishSeconds: polishSeconds)
                meetingRef.status = .done
                try? self.modelContext?.save()
            }
        }

        isRecording = false
        elapsedTime = 0
        recordingStartTime = nil
        translationSession = false
        translationStore.forced = false
        refreshWhisperTranslate()
    }

    // MARK: - File Import

    /// Import an existing audio file as a new meeting: copy it into app storage,
    /// transcribe the whole file on-device, then run the same diarization + report
    /// chain a live recording gets. Returns the created meeting (already inserted,
    /// status `.processing`) so the caller can select it; nil if it couldn't start.
    @discardableResult
    func importAudioFile(from pickedURL: URL, modelContext: ModelContext) -> Meeting? {
        self.modelContext = modelContext
        // One owner of WhisperKit at a time: refuse while recording or importing.
        guard !isRecording, !isStarting, !isStopping, importProgress == nil,
              transcriptionEngine.isReady else { return nil }

        // A user-picked file lives outside the sandbox — open the scope to copy it.
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        let name = pickedURL.deletingPathExtension().lastPathComponent
        let ext = pickedURL.pathExtension.isEmpty ? "m4a" : pickedURL.pathExtension
        // Copy in, so playback and diarization survive the original moving/deleting.
        let dest = AudioCaptureManager.storageDirectory()
            .appendingPathComponent("import_\(Int(Date().timeIntervalSince1970)).\(ext)")
        do {
            try FileManager.default.copyItem(at: pickedURL, to: dest)
        } catch {
            NSLog("Parrot: import copy failed — \(error.localizedDescription)")
            return nil
        }

        // Land under the file's own date, so a recording from last week reads as
        // last week rather than "now".
        let fileDate = (try? pickedURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .now

        let meeting = Meeting(title: name, date: fileDate, systemAudioPath: dest.path)
        meeting.status = .processing
        let profile = profileStore.activeProfile
        meeting.profile = profile
        meeting.profileSnapshotData = profile.flatMap { try? JSONEncoder().encode($0.kinds) }
        modelContext.insert(meeting)
        try? modelContext.save()

        importProgress = ImportProgress(fileName: name, phase: .transcribing)
        let ref = meeting
        Task { await runImport(meeting: ref, audioURL: dest) }
        return meeting
    }

    private func runImport(meeting: Meeting, audioURL: URL) async {
        defer { importProgress = nil }

        // 1. Whole-file, on-device transcription. Every segment is "Them" (one
        //    mixed track, no mic channel to tag "Me"); diarization splits it below.
        do {
            let results = try await transcriptionEngine.transcribeFile(url: audioURL)
            guard !results.isEmpty else {
                meeting.status = .failed
                meeting.errorMessage = "No speech found in this file."
                try? modelContext?.save()
                return
            }
            for result in results {
                let segment = TranscriptSegment(
                    startTime: result.startTime, endTime: result.endTime,
                    text: result.text, speakerLabel: result.source.label,
                    confidence: result.confidence)
                modelContext?.insert(segment)
                segment.meeting = meeting
            }
            // Real audio length (trailing silence included) for stats/cost.
            if let file = try? AVAudioFile(forReading: audioURL) {
                meeting.duration = Double(file.length) / file.fileFormat.sampleRate
            } else {
                meeting.duration = results.last?.endTime ?? 0
            }
            try? modelContext?.save()
        } catch {
            meeting.status = .failed
            meeting.errorMessage = "Couldn't transcribe this file. \(error.localizedDescription)"
            try? modelContext?.save()
            return
        }

        // 2. Same post-call chain as a recording: diarization refines the speaker
        //    labels and flips status to .done; the summary runs when the copilot
        //    is configured. Coaching is skipped — no "Me" channel to measure.
        importProgress?.phase = .analyzing
        await postProcess(meeting: meeting)
        if callAnalysisEngine.isEnabled, callAnalysisEngine.provider.isConfigured {
            callAnalysisEngine.provider.resetUsage()
            await generateSummary(meeting: meeting, includeCoaching: false)
        }
        writeAIUsage(meeting: meeting, polishSeconds: 0, backendOverride: .local)
        meeting.status = .done
        try? modelContext?.save()
    }

    // MARK: - Deletion

    /// Deletes a meeting and its audio files. The only removal path in the app —
    /// without it storage grows forever. Refuses the active recording.
    func delete(_ meeting: Meeting) {
        guard !(isRecording && meeting.id == currentMeeting?.id) else { return }
        for path in [meeting.systemAudioPath.nilIfEmpty, meeting.micAudioPath?.nilIfEmpty].compactMap({ $0 }) {
            try? FileManager.default.removeItem(atPath: path)
        }
        if currentMeeting?.id == meeting.id { currentMeeting = nil }
        modelContext?.delete(meeting)
        try? modelContext?.save()
    }

    // MARK: - Segment Storage

    private func addSegment(_ result: TranscriptionEngine.TranscriptionResult) {
        // Use the live meeting object directly. The previous code looked the
        // meeting up via model(for: meetingID) where meetingID was captured before
        // the context was saved — i.e. a TEMPORARY identifier that goes stale after
        // save. Resolving that stale id returned a malformed object and assigning it
        // to segment.meeting tripped a SwiftData assertion (crash). currentMeeting
        // is the same registered instance in the same context, set before any
        // segment can arrive.
        guard let modelContext, let meeting = currentMeeting else { return }

        // Speaker bleed: without headphones the mic hears the speakers, the
        // AEC attenuates but can't always erase it, and the residual decodes —
        // the same sentence then lands twice, "Them" from system audio and
        // "Me" from the mic (and inflates diarization/talk-ratio). The system
        // copy is authoritative for anything both streams heard, so a Me
        // segment that near-duplicates a Them segment within a beat is echo,
        // whichever order they decoded in. (Surfaced by the speakers-playback
        // live test 2026-08-01; previously masked by the glossary decode bug.)
        let bleedWindow: TimeInterval = 2.5
        let neighbors = meeting.segments.filter { abs($0.startTime - result.startTime) <= bleedWindow }
        if result.source == .me,
           neighbors.contains(where: { $0.speakerLabel == AudioSource.them.label
               && Self.isEchoDuplicate($0.text, result.text) }) {
            return
        }
        if result.source == .them {
            for stored in neighbors where stored.speakerLabel == AudioSource.me.label
                && Self.isEchoDuplicate(stored.text, result.text) {
                modelContext.delete(stored)
            }
        }

        let segment = TranscriptSegment(
            startTime: result.startTime,
            endTime: result.endTime,
            text: result.text,
            speakerLabel: result.source.label,
            confidence: result.confidence
        )

        modelContext.insert(segment)
        segment.meeting = meeting
        _ = saveContext(modelContext)
        if let english = result.translation, !english.isEmpty {
            translationStore.applySpeech(segment.id, english)
        }
        translationStore.enqueue([segment])
    }

    @discardableResult
    private func saveContext(_ context: ModelContext) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            NSLog("Parrot: SwiftData save failed — \(error.localizedDescription)")
            persistenceNotice = "Couldn't save the transcript — earlier lines may still be on disk."
            return false
        }
    }

    /// Near-verbatim match for the echo-dedup above: Whisper decodes the bleed
    /// with small variances ("I am" vs "I'm"), so exact equality is too strict.
    /// High token overlap + the tight time window keeps a human genuinely
    /// echoing the other side (rare inside 2.5s) from being eaten.
    nonisolated static func isEchoDuplicate(_ a: String, _ b: String) -> Bool {
        func tokens(_ s: String) -> Set<String> {
            Set(s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 })
        }
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        return Double(ta.intersection(tb).count) / Double(min(ta.count, tb.count)) >= 0.8
    }

    // MARK: - Post-Call Summary

    /// `includeCoaching` is false for imported files: a single mixed track has no
    /// "Me" channel, so talk-ratio/coaching would be measured against 0% and read
    /// as broken. The summary itself works fine from any transcript.
    private func generateSummary(meeting: Meeting, includeCoaching: Bool = true,
                                 translation: TranslationContext? = nil) async {
        let segments = meeting.sortedSegments
        guard !segments.isEmpty else { return }

        let transcript = segments
            .map { "[\($0.formattedTimestamp)] \(meeting.displayName(forSpeaker: $0.speakerLabel)): \($0.text)" }
            .joined(separator: "\n")
        let insightTitles = meeting.sortedInsights.map { "\($0.style.label): \($0.title)" }
        var instructions = meeting.profile?.tone ?? (UserDefaults.standard.string(forKey: "copilotInstructions") ?? "")
        if let translation {
            instructions = [translation.reportInstructions, instructions]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
        let counterpart = meeting.profile?.counterpart ?? "the other person"

        do {
            let summary = try await callAnalysisEngine.provider.summarize(
                transcript: transcript,
                insightTitles: insightTitles,
                instructions: instructions,
                counterpart: counterpart
            )
            meeting.summary = summary
            try? modelContext?.save()
        } catch {
            // Best-effort: the transcript and insights are already saved.
        }

        guard includeCoaching else { return }

        // Coaching + follow-ups report, with the user's real talk balance.
        let meWords = segments
            .filter { $0.speakerLabel == "Me" }
            .reduce(0) { $0 + $1.text.split(separator: " ").count }
        let totalWords = segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
        let talkPercentMe = totalWords > 0 ? Int(Double(meWords) / Double(totalWords) * 100) : 0
        do {
            let coaching = try await callAnalysisEngine.provider.coachingReport(
                transcript: transcript,
                talkPercentMe: talkPercentMe,
                instructions: instructions,
                counterpart: counterpart
            )
            meeting.coaching = coaching
            try? modelContext?.save()
        } catch {
            // Best-effort.
        }
    }

    // MARK: - Post-call polish

    /// Re-transcribe saved audio through the chosen Hybrid/Cloud vendor.
    /// Local polish mode skips. Failure leaves the live transcript untouched.
    @discardableResult
    private func polishTranscript(meeting: Meeting) async -> Double {
        let mode = FeatureProcessing.polish
        guard mode != .local, let modelContext else { return 0 }
        if CloudVendor.selected.speechKey() == nil {
            transcriptionEngine.postNotice("Cloud vendor key missing — keeping the live transcript")
            return hybridRefiner.billedSeconds
        }

        do {
            let polished: [TranscriptPolisher.PolishedSegment]
            if mode == .hybrid {
                // Mid-call refine already patched completed windows; polish
                // only the leftover tail so we don't pay for the whole call twice.
                let last = meeting.sortedSegments.last?.endTime ?? 0
                let tailStart = max(0, last - FeatureProcessing.refineOverlap)
                await hybridRefiner.refine(
                    meeting: meeting, start: tailStart, end: max(meeting.duration, last),
                    context: modelContext, smart: true)
                return hybridRefiner.billedSeconds
            } else {
                polished = try await HybridRefiner.polishTracks(
                    systemPath: meeting.systemAudioPath.nilIfEmpty,
                    micPath: meeting.micAudioPath?.nilIfEmpty,
                    smart: true)
            }
            guard !polished.isEmpty else { return hybridRefiner.billedSeconds }
            guard TranscriptPolisher.replaceAll(polished, on: meeting, context: modelContext) else {
                persistenceNotice = "Couldn't save the polished transcript — live lines kept."
                return hybridRefiner.billedSeconds
            }
            NSLog("Parrot: transcript polished — \(polished.count) segments")
            let tracks = [meeting.systemAudioPath.nilIfEmpty, meeting.micAudioPath?.nilIfEmpty]
                .compactMap { $0 }.count
            return hybridRefiner.billedSeconds + meeting.duration * Double(tracks)
        } catch {
            NSLog("Parrot: polish failed, keeping live transcript — \(error.localizedDescription)")
            transcriptionEngine.postNotice("Polish failed — live transcript kept")
            return hybridRefiner.billedSeconds
        }
    }

    /// Copy live translation lines onto segments so they survive Stop.
    private func persistTranslations(_ lines: [UUID: String], onto meeting: Meeting) {
        for segment in meeting.segments {
            if let text = lines[segment.id], !text.isEmpty {
                segment.translation = text
            }
        }
        try? modelContext?.save()
    }

    /// Translate every spoken line with the Translation mode: local model,
    /// then Gemini on Hybrid / Cloud. Safe to run again from the meeting tab.
    func translateTranscript(meeting: Meeting, replaceExisting: Bool = false) async {
        guard translatingMeetingID == nil else { return }
        translatingMeetingID = meeting.id
        transcriptTranslateNotice = nil
        defer {
            translatingMeetingID = nil
            LocalTextModel.unloadAfterLocalTranslation()
        }
        if FeatureProcessing.translation == .local {
            do {
                try await LocalTextModel.shared.ensureLoaded(FeatureProcessing.translationOllamaModel)
            } catch {
                transcriptTranslateNotice = error.localizedDescription
            }
        }

        if meeting.translationTargetCode.isEmpty {
            meeting.translationTargetCode = translationStore.target
        }
        let target = meeting.translationTargetCode
        let name = TranslationLanguage(rawValue: target)?.promptName ?? target
        let instruction = "Translate the following into \(name) (\(target)). Reply with only the translation. Do not use any other language."
        let mode = FeatureProcessing.translation
        var skipLocal = false
        let polishAfter = TranslationRouting.usesGemini(mode)
            && CloudVendor.selected == .gemini
            && meetingHasAudio(meeting)
        if polishAfter {
            await polishTranslation(meeting: meeting, target: target, replaceExisting: true)
        }
        let destinations = TranslationRouting.destinations(for: mode)

        for segment in meeting.sortedSegments {
            let source = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { continue }
            if LocalTranslation.isSameLanguage(target: target) {
                segment.translation = source
                continue
            }
            if !replaceExisting || polishAfter, !segment.translation.isEmpty { continue }
            for destination in destinations {
                if destination == .local, skipLocal { continue }
                do {
                    let out = try await TextRewriter.rewrite(
                        source, instruction: instruction, destination: destination,
                        model: destination == .local ? FeatureProcessing.translationOllamaModel : nil)
                    if !out.isEmpty { segment.translation = out }
                } catch {
                    if destination == .local, TextRewriter.isLocalUnavailable(error) {
                        skipLocal = true
                        if mode == .local {
                            transcriptTranslateNotice = LocalTranslation.unavailableMessage(target: target)
                        }
                        continue
                    }
                    if let rewrite = error as? TextRewriter.RewriteError, case .overCap = rewrite {
                        continue
                    }
                    transcriptTranslateNotice = error.localizedDescription
                    continue
                }
            }
        }
        try? modelContext?.save()
    }

    private func meetingHasAudio(_ meeting: Meeting) -> Bool {
        [meeting.systemAudioPath.nilIfEmpty, meeting.micAudioPath?.nilIfEmpty]
            .compactMap { $0 }
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// After the spoken transcript is final, re-translate the saved audio
    /// with `gemini-3.5-live-translate-preview`. Failure keeps live lines.
    private func polishTranslation(meeting: Meeting, target: String, replaceExisting: Bool) async {
        guard TranslationRouting.usesGemini(FeatureProcessing.translation) else { return }
        guard CloudVendor.selected == .gemini else { return }
        guard let key = CloudVendor.gemini.speechKey() else { return }
        let code = TranslationLanguage(rawValue: target)?.bcp47 ?? target
        let segments = meeting.sortedSegments
        var any = false
        do {
            for (path, mine) in [
                (meeting.systemAudioPath.nilIfEmpty, false),
                (meeting.micAudioPath?.nilIfEmpty, true),
            ] as [(String?, Bool)] {
                guard let path else { continue }
                let samples = try AudioFileLoader.load16kMono(url: URL(fileURLWithPath: path))
                guard !samples.isEmpty else { continue }
                let rows = try await GeminiLiveTranslator.translateTrack(
                    samples: samples, targetBCP47: code, apiKey: key)
                let paired = segments.enumerated().filter {
                    mine ? $0.element.speakerLabel == "Me" : $0.element.speakerLabel != "Me"
                }
                let assigned = TranslationAssigner.apply(
                    translations: rows.map { ($0.start, $0.end, $0.text) },
                    segments: paired.map { ($0.element.startTime, $0.element.endTime) })
                for (local, text) in assigned where !text.isEmpty {
                    let index = paired[local].offset
                    if !replaceExisting, !segments[index].translation.isEmpty { continue }
                    segments[index].translation = text
                    any = true
                }
            }
        } catch {
            NSLog("Parrot: post-call translation failed — \(error.localizedDescription)")
            translationStore.notice = any
                ? "Post-call translation failed — earlier lines kept"
                : "Post-call translation failed — try Translate transcript again"
            return
        }
        if any { try? modelContext?.save() }
    }

    // MARK: - AI usage snapshot

    /// Freezes this call's AI usage (copilot tokens + transcription/polish audio
    /// seconds) onto the meeting so the detail view can show what it cost.
    private func writeAIUsage(meeting: Meeting, polishSeconds: Double,
                              backendOverride: TranscriptionBackend? = nil) {
        var usage = AIUsage()
        // ponytail: reads the copilot provider/model at stop time, same accepted
        // mid-call-switch edge as the transcription backend below.
        if let switching = callAnalysisEngine.provider as? SwitchingAnalysisProvider {
            let live = switching.liveUsage
            usage.copilotModel = live.model
            usage.copilotProvider = live.provider
            usage.copilot = live.totals
            // Second bucket only when reports ran on a different backend.
            if let reports = switching.reportsUsage {
                usage.reportsModel = reports.model
                usage.reportsProvider = reports.provider
                usage.reports = reports.totals
            }
        } else {
            usage.copilotModel = CopilotProviderKind.activeModelName
            usage.copilotProvider = CopilotProviderKind.selected.rawValue
            usage.copilot = callAnalysisEngine.provider.usageTotals
        }
        // ponytail: reads the backend setting at stop time; a mid-call engine
        // switch or cloud→local fallback mislabels one estimated row. Import
        // passes an override since it's always on-device regardless of the setting.
        usage.transcriptionBackend = (backendOverride ?? TranscriptionBackend.liveEngine()).rawValue
        usage.transcriptionSeconds = meeting.duration
        usage.transcriptionTracks = meeting.micAudioPath?.nilIfEmpty != nil ? 2 : 1
        usage.polishSeconds = polishSeconds
        usage.polishVendor = polishSeconds > 0 ? CloudVendor.selected.rawValue : nil
        meeting.aiUsageData = try? JSONEncoder().encode(usage)
        try? modelContext?.save()
    }

    // MARK: - Post-Processing

    /// Re-runs diarization on a finished meeting (audio is retained). Safe to
    /// call repeatedly; refuses the meeting currently being recorded.
    func redetectSpeakers(meeting: Meeting) async {
        guard !(isRecording && meeting.id == currentMeeting?.id) else { return }
        await postProcess(meeting: meeting)
    }

    private func postProcess(meeting: Meeting) async {
        // Status stays .processing here — the calling chain flips .done after
        // the post-call REPORT finishes, so the UI can say "writing report…"
        // instead of the misleading "no report was generated".
        guard let audioPath = meeting.systemAudioPath.nilIfEmpty,
              FileManager.default.fileExists(atPath: audioPath) else { return }

        do {
            let audioURL = URL(fileURLWithPath: audioPath)
            let output = try await diarizationEngine.diarize(audioURL: audioURL)

            // Assign speaker labels to transcript segments by time overlap.
            // "Me" segments come from the mic stream and are already attributed;
            // diarization only refines who's who within the system audio ("Them").
            for transcriptSegment in meeting.segments where transcriptSegment.speakerLabel != "Me" {
                if let label = Self.diarizedLabel(
                    for: (transcriptSegment.startTime, transcriptSegment.endTime),
                    turns: output.segments) {
                    transcriptSegment.speakerLabel = label
                }
            }
            meeting.speakerEmbeddingsData = try? JSONEncoder().encode(output.embeddings)
            try? modelContext?.save()
        } catch {
            // Diarization is a refinement pass; the audio and transcript are
            // already saved. Keep the generic "Them" labels rather than showing
            // a perfectly good meeting as failed.
            NSLog("Parrot: diarization failed — \(error.localizedDescription)")
            try? modelContext?.save()
        }
    }

    /// Best speaker turn for a transcript segment: max time overlap, else the
    /// nearest turn in time — so every non-Me segment gets a label instead of
    /// leaving stray "Them" holes where diarization saw no speech.
    nonisolated static func diarizedLabel(
        for segment: (start: TimeInterval, end: TimeInterval),
        turns: [DiarizationEngine.SpeakerSegmentResult]
    ) -> String? {
        var best: (label: String, overlap: TimeInterval)?
        var nearest: (label: String, gap: TimeInterval)?
        for turn in turns {
            let overlap = min(turn.endTime, segment.end) - max(turn.startTime, segment.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (turn.speakerLabel, overlap) }
            let gap = max(turn.startTime - segment.end, segment.start - turn.endTime)
            if nearest == nil || gap < nearest!.gap { nearest = (turn.speakerLabel, gap) }
        }
        return best?.label ?? nearest?.label
    }

    var formattedElapsedTime: String {
        let hours = Int(elapsedTime) / 3600
        let minutes = (Int(elapsedTime) % 3600) / 60
        let seconds = Int(elapsedTime) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

enum RecordingError: LocalizedError {
    case modelNotReady

    var errorDescription: String? {
        switch self {
        case .modelNotReady: "WhisperKit model is not loaded yet. Please wait."
        }
    }
}
