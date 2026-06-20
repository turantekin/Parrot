import SwiftUI
import SwiftData

/// Orchestrates audio capture, transcription, and storage for a recording session.
@MainActor
@Observable
final class RecordingManager {
    let audioCaptureManager = AudioCaptureManager()
    let transcriptionEngine = TranscriptionEngine()
    let diarizationEngine = DiarizationEngine()
    let callAnalysisEngine = CallAnalysisEngine()
    let knowledgeBase = KnowledgeBaseService()

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
    private var timer: Timer?
    private var modelContext: ModelContext?

    init() {
        callAnalysisEngine.knowledgeBase = knowledgeBase
    }

    /// Initialize and load the default WhisperKit model
    func prepare(modelContext: ModelContext) async {
        self.modelContext = modelContext
        Self.reconcileOrphanedRecordings(in: modelContext)
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

    func startRecording(modelContext: ModelContext) async throws {
        self.modelContext = modelContext
        // Reject re-entry up front (before any await) so a double-trigger can't
        // start two recordings / two transcription loops.
        guard !isRecording, !isStarting else { return }
        guard transcriptionEngine.isReady else {
            throw RecordingError.modelNotReady
        }
        isStarting = true
        defer { isStarting = false }

        // Create meeting
        let meeting = Meeting()
        modelContext.insert(meeting)

        // Set up audio capture
        try await audioCaptureManager.startCapture()
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
        callAnalysisEngine.start(profile: nil, brief: nextCallBrief)

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
        guard isRecording else { return }

        timer?.invalidate()
        timer = nil

        // Stop transcription and the copilot first
        transcriptionEngine.stopTranscribing()
        callAnalysisEngine.stop()

        // Stop audio capture
        await audioCaptureManager.stopCapture()

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

            // Start post-processing (diarization)
            let meetingRef = meeting
            Task {
                await self.postProcess(meeting: meetingRef)
            }

            // Generate the post-call report in the background (best-effort)
            if callAnalysisEngine.isEnabled, callAnalysisEngine.provider.isConfigured {
                Task {
                    await self.generateSummary(meeting: meetingRef)
                }
            }
        }

        isRecording = false
        elapsedTime = 0
        recordingStartTime = nil
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
        let instructions = UserDefaults.standard.string(forKey: "copilotInstructions") ?? ""

        do {
            let summary = try await callAnalysisEngine.provider.summarize(
                transcript: transcript,
                insightTitles: insightTitles,
                instructions: instructions
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
                instructions: instructions
            )
            meeting.coaching = coaching
            try? modelContext?.save()
        } catch {
            // Best-effort.
        }
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
            meeting.status = .failed
            meeting.errorMessage = error.localizedDescription
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
