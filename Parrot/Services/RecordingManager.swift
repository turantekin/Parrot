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
    let callAnalysisEngine = CallAnalysisEngine()
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

    /// Initialize and load the default WhisperKit model
    func prepare(modelContext: ModelContext) async {
        self.modelContext = modelContext
        recoverInterruptedRecordings(in: modelContext)
        profileStore.seedAndMigrateIfNeeded(context: modelContext, knowledgeBase: knowledgeBase)
        await transcriptionEngine.loadModel(
            UserDefaults.standard.string(forKey: "whisperModel") ?? "base"
        )
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
    }

    // MARK: - Recording Control

    /// The one shared entry point for every "start recording" button — checks
    /// permissions, then starts. Returns without starting (and without throwing)
    /// when a permission flow was triggered instead.
    func preflightPermissionsAndStart(modelContext: ModelContext) async throws {
        // Check Screen Recording permission BEFORE touching any ScreenCaptureKit
        // API. Calling SCShareableContent while unauthorized makes macOS pop its
        // own prompt AND throws — the app then showed a second custom alert,
        // hence two dialogs. Preflight, trigger the single official prompt if
        // needed, stop.
        guard CGPreflightScreenCaptureAccess() else {
            if !CGRequestScreenCaptureAccess() {
                // Previously denied: macOS won't re-prompt, so guide the user
                // straight to the right Settings pane.
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return
        }

        // Ensure the microphone is authorized so the user's own voice ("Me")
        // is captured. Without this the engine runs but feeds silence.
        // Non-fatal: system audio still records if denied.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        default:
            break
        }

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
        transcriptionEngine.startTranscribing(meetingStartTime: .now)
        callAnalysisEngine.provider.resetUsage()  // this call's token meter starts at zero
        callAnalysisEngine.start(profile: profile, brief: nextCallBrief)

        currentMeeting = meeting
        recordingStartTime = .now
        isRecording = true

        // Start elapsed time timer
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartTime else { return }
                self.elapsedTime = Date.now.timeIntervalSince(start)
            }
        }

        try modelContext.save()
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
            Task {
                let polishSeconds = await self.polishTranscript(meeting: meetingRef)
                await self.postProcess(meeting: meetingRef)
                if self.callAnalysisEngine.isEnabled, self.callAnalysisEngine.provider.isConfigured {
                    await self.generateSummary(meeting: meetingRef)
                }
                // Last in the chain so the meter has seen the summary/coaching calls too.
                self.writeAIUsage(meeting: meetingRef, polishSeconds: polishSeconds)
            }
        }

        isRecording = false
        elapsedTime = 0
        recordingStartTime = nil
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

        let segment = TranscriptSegment(
            startTime: result.startTime,
            endTime: result.endTime,
            text: result.text,
            speakerLabel: result.source.label,
            confidence: result.confidence
        )

        modelContext.insert(segment)
        segment.meeting = meeting
        try? modelContext.save()
    }

    // MARK: - Post-Call Summary

    /// `includeCoaching` is false for imported files: a single mixed track has no
    /// "Me" channel, so talk-ratio/coaching would be measured against 0% and read
    /// as broken. The summary itself works fine from any transcript.
    private func generateSummary(meeting: Meeting, includeCoaching: Bool = true) async {
        let segments = meeting.sortedSegments
        guard !segments.isEmpty else { return }

        let transcript = segments
            .map { "[\($0.formattedTimestamp)] \($0.speakerLabel ?? "Speaker"): \($0.text)" }
            .joined(separator: "\n")
        let insightTitles = meeting.sortedInsights.map { "\($0.style.label): \($0.title)" }
        let instructions = meeting.profile?.tone ?? (UserDefaults.standard.string(forKey: "copilotInstructions") ?? "")
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

    /// Re-transcribe the saved audio through Groq's large model and replace the
    /// live transcript with the cleaner one. Opt-in, best-effort: any failure
    /// leaves the live transcript untouched.
    /// Returns the seconds of audio billed (all tracks summed) for cost tracking,
    /// 0 when polish didn't run.
    @discardableResult
    private func polishTranscript(meeting: Meeting) async -> Double {
        guard UserDefaults.standard.bool(forKey: "polishAfterCall"),
              let key = APIKeyStore.load(account: TranscriptionBackend.groq.keychainAccount!),
              !key.isEmpty,
              let modelContext else { return 0 }

        let setting = UserDefaults.standard.string(forKey: "transcriptionLanguage")
        let language = (setting == nil || setting == "auto") ? nil : setting

        do {
            let polished = try await TranscriptPolisher.polish(
                systemPath: meeting.systemAudioPath.nilIfEmpty,
                micPath: meeting.micAudioPath?.nilIfEmpty,
                language: language,
                apiKey: key
            )
            guard !polished.isEmpty else { return 0 }

            for old in meeting.segments {
                modelContext.delete(old)
            }
            for s in polished {
                let segment = TranscriptSegment(
                    startTime: s.start, endTime: s.end,
                    text: s.text, speakerLabel: s.speaker, confidence: nil)
                modelContext.insert(segment)
                segment.meeting = meeting
            }
            try? modelContext.save()
            NSLog("Parrot: transcript polished — \(polished.count) segments")
            // Billed audio ≈ call duration per re-transcribed track.
            let tracks = [meeting.systemAudioPath.nilIfEmpty, meeting.micAudioPath?.nilIfEmpty]
                .compactMap { $0 }.count
            return meeting.duration * Double(tracks)
        } catch {
            NSLog("Parrot: polish failed, keeping live transcript — \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - AI usage snapshot

    /// Freezes this call's AI usage (copilot tokens + transcription/polish audio
    /// seconds) onto the meeting so the detail view can show what it cost.
    private func writeAIUsage(meeting: Meeting, polishSeconds: Double,
                              backendOverride: TranscriptionBackend? = nil) {
        var usage = AIUsage()
        usage.copilotModel = ClaudeAnalysisProvider.model
        usage.copilot = callAnalysisEngine.provider.usageTotals
        // ponytail: reads the backend setting at stop time; a mid-call engine
        // switch or cloud→local fallback mislabels one estimated row. Import
        // passes an override since it's always on-device regardless of the setting.
        usage.transcriptionBackend = (backendOverride ?? TranscriptionBackend.selected).rawValue
        usage.transcriptionSeconds = meeting.duration
        usage.transcriptionTracks = meeting.micAudioPath?.nilIfEmpty != nil ? 2 : 1
        usage.polishSeconds = polishSeconds
        meeting.aiUsageData = try? JSONEncoder().encode(usage)
        try? modelContext?.save()
    }

    // MARK: - Post-Processing

    private func postProcess(meeting: Meeting) async {
        guard let audioPath = meeting.systemAudioPath.nilIfEmpty,
              FileManager.default.fileExists(atPath: audioPath) else {
            meeting.status = .done
            try? modelContext?.save()
            return
        }

        do {
            let audioURL = URL(fileURLWithPath: audioPath)
            let speakerSegments = try await diarizationEngine.diarize(audioURL: audioURL)

            // Assign speaker labels to transcript segments by time overlap.
            // "Me" segments come from the mic stream and are already attributed;
            // diarization only refines who's who within the system audio ("Them").
            for transcriptSegment in meeting.segments {
                guard transcriptSegment.speakerLabel != "Me" else { continue }
                let bestMatch = speakerSegments.max { a, b in
                    overlap(a, transcriptSegment) < overlap(b, transcriptSegment)
                }
                if let match = bestMatch, overlap(match, transcriptSegment) > 0 {
                    transcriptSegment.speakerLabel = match.speakerLabel
                }
            }
            meeting.status = .done
            try? modelContext?.save()
        } catch {
            // Diarization is a refinement pass; the audio and transcript are
            // already saved. Keep the generic "Them" labels rather than showing
            // a perfectly good meeting as failed.
            NSLog("Parrot: diarization failed — \(error.localizedDescription)")
            meeting.status = .done
            try? modelContext?.save()
        }
    }

    /// Calculate time overlap between a speaker segment and transcript segment
    private nonisolated func overlap(
        _ speaker: DiarizationEngine.SpeakerSegmentResult,
        _ transcript: TranscriptSegment
    ) -> TimeInterval {
        let overlapStart = max(speaker.startTime, transcript.startTime)
        let overlapEnd = min(speaker.endTime, transcript.endTime)
        return max(0, overlapEnd - overlapStart)
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
