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

    init() {
        callAnalysisEngine.knowledgeBase = knowledgeBase
    }

    /// Initialize and load the default WhisperKit model
    func prepare(modelContext: ModelContext) async {
        self.modelContext = modelContext
        Self.reconcileOrphanedRecordings(in: modelContext)
        profileStore.seedAndMigrateIfNeeded(context: modelContext, knowledgeBase: knowledgeBase)
        await transcriptionEngine.loadModel(
            UserDefaults.standard.string(forKey: "whisperModel") ?? "base"
        )
    }

    /// A meeting left in `.recording` or `.processing` means a previous session was
    /// killed (crash or force-quit) before it could finish. Those can never resume
    /// and their audio file was never finalized, so mark them failed instead of
    /// letting them linger as if active.
    private static func reconcileOrphanedRecordings(in context: ModelContext) {
        guard let meetings = try? context.fetch(FetchDescriptor<Meeting>()) else { return }
        var changed = false
        for meeting in meetings where meeting.status == .recording || meeting.status == .processing {
            meeting.status = .failed
            if meeting.errorMessage == nil {
                meeting.errorMessage = "Recording was interrupted before it finished."
            }
            changed = true
        }
        if changed { try? context.save() }
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
        // start two recordings / two transcription loops.
        guard !isRecording, !isStarting, !isStopping else { return }
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

    private func generateSummary(meeting: Meeting) async {
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
    private func writeAIUsage(meeting: Meeting, polishSeconds: Double) {
        var usage = AIUsage()
        usage.copilotModel = ClaudeAnalysisProvider.model
        usage.copilot = callAnalysisEngine.provider.usageTotals
        // ponytail: reads the backend setting at stop time; a mid-call engine
        // switch or cloud→local fallback mislabels one estimated row.
        usage.transcriptionBackend = TranscriptionBackend.selected.rawValue
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
