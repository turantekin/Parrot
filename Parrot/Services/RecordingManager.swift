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

    private(set) var isRecording = false
    private(set) var recordingStartTime: Date?
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var currentMeeting: Meeting?

    private var timer: Timer?
    private var modelContext: ModelContext?

    /// Initialize and load the default WhisperKit model
    func prepare(modelContext: ModelContext) async {
        self.modelContext = modelContext
        await transcriptionEngine.loadModel(
            UserDefaults.standard.string(forKey: "whisperModel") ?? "base"
        )
    }

    // MARK: - Recording Control

    func startRecording(modelContext: ModelContext) async throws {
        self.modelContext = modelContext
        guard !isRecording else { return }
        guard transcriptionEngine.isReady else {
            throw RecordingError.modelNotReady
        }

        // Create meeting
        let meeting = Meeting()
        modelContext.insert(meeting)

        // Set up audio capture
        try await audioCaptureManager.startCapture()
        meeting.systemAudioPath = audioCaptureManager.systemAudioURL?.path ?? ""
        meeting.micAudioPath = audioCaptureManager.micAudioURL?.path

        // Wire audio to transcription
        audioCaptureManager.onAudioBuffer = { [weak self] buffer in
            self?.transcriptionEngine.appendAudio(buffer)
        }

        // Wire transcription output to storage and the live copilot
        let meetingID = meeting.persistentModelID
        transcriptionEngine.onSegment = { [weak self] result in
            Task { @MainActor in
                self?.addSegment(result, meetingID: meetingID)
                self?.callAnalysisEngine.ingest(text: result.text, at: result.endTime)
            }
        }

        // Start transcription and the copilot loop
        transcriptionEngine.startTranscribing(meetingStartTime: .now)
        callAnalysisEngine.start()

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

            // Persist the copilot's insights so they survive into the meeting report
            for insight in callAnalysisEngine.insights {
                let stored = CallInsight(from: insight)
                stored.meeting = meeting
                meeting.insights.append(stored)
                modelContext?.insert(stored)
            }
            try? modelContext?.save()

            // Start post-processing (diarization)
            let meetingRef = meeting
            Task {
                await self.postProcess(meeting: meetingRef)
            }
        }

        isRecording = false
        elapsedTime = 0
        recordingStartTime = nil
    }

    // MARK: - Segment Storage

    private func addSegment(_ result: TranscriptionEngine.TranscriptionResult, meetingID: PersistentIdentifier) {
        guard let modelContext else { return }

        let segment = TranscriptSegment(
            startTime: result.startTime,
            endTime: result.endTime,
            text: result.text,
            confidence: result.confidence
        )

        if let meeting = modelContext.model(for: meetingID) as? Meeting {
            segment.meeting = meeting
            meeting.segments.append(segment)
        }

        modelContext.insert(segment)
        try? modelContext.save()
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

            // Assign speaker labels to transcript segments by time overlap
            for transcriptSegment in meeting.segments {
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
