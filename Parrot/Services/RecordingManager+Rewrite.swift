import Foundation
import SwiftData

/// "Rewrite Report" (Profiles 2.0, R3): the report and coaching are written
/// again from the transcript with a profile's current report template, and
/// the meeting moves to that profile. One level of undo: the report it
/// replaced is kept on the meeting (`Meeting.previousReport`).
extension RecordingManager {

    private func rewriteFailure(_ text: String) -> Error {
        CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: text])
    }

    /// All or nothing: the old report stays unless a new summary came back.
    /// Never re-runs the after-call actions (webhook, Reminders, export):
    /// a rewrite is a new reading, not a new call.
    // ponytail: the rewrite's tokens aren't added to the meeting's cost row.
    func rewriteReport(_ meeting: Meeting, with profile: CallProfile) async throws {
        guard meeting.status == .done, !meeting.segments.isEmpty else {
            throw rewriteFailure("This meeting has no transcript to rewrite from.")
        }
        guard !isRecording else { throw rewriteFailure("Parrot is recording. Rewrite the report after the call.") }
        guard callAnalysisEngine.provider.isConfigured else {
            throw rewriteFailure("Set up the Assistant's AI in Settings first.")
        }

        // Privacy only ever tightens. A private profile makes the meeting
        // private from now on (like recording under it would have), and a
        // private meeting is always rewritten on this Mac, whatever profile.
        let makesPrivate = profile.onDeviceOnly
        let local = makesPrivate || !CloudGate.mayLeaveMac(meeting) || CloudGate.forcesLocal

        let template = profile.reportTemplate
        let provider = callAnalysisEngine.provider
        let transcript = meeting.promptTranscript
        let insightTitles = meeting.sortedInsights.map { "\($0.style.label): \($0.title)" }
        let bookmarks = meeting.bookmarks.map(\.promptLine)
        // Imports have no "Me" channel to coach (same rule as the first report).
        let coach = template.coachingEnabled && meeting.importedAt == nil
        let talk = meeting.talkPercentMe ?? 0

        let (summary, coaching) = try await CloudGate.$scopeLocal.withValue(local) {
            let summary = try await provider.summarize(
                transcript: transcript, insightTitles: insightTitles, bookmarks: bookmarks,
                instructions: profile.tone, counterpart: profile.counterpart, template: template)
            let coaching = coach ? try? await provider.coachingReport(
                transcript: transcript, talkPercentMe: talk, instructions: profile.tone,
                counterpart: profile.counterpart, template: template) : nil
            return (summary, coaching)
        }
        // Cancelled while the AI was writing (the sheet's Cancel): keep the old one.
        try Task.checkCancellation()

        meeting.previousReport = PreviousReport(summary: meeting.summary, coaching: meeting.coaching,
                                                templateData: meeting.reportTemplateData, profileID: meeting.profile?.id)
        meeting.profile = profile
        // Only after success: a failed rewrite leaves the meeting as it was.
        // Undo never clears it.
        if makesPrivate { meeting.onDeviceOnly = true }
        meeting.reportTemplateData = template.isStandard ? nil : try? JSONEncoder().encode(template)
        meeting.summary = summary
        meeting.coaching = coaching
        try? modelContext?.save()
        await memory.index(meeting)
    }

    /// Puts back the report the last rewrite replaced. Privacy stays as it
    /// is: an undo never makes a meeting less private.
    func undoRewrite(_ meeting: Meeting) async {
        guard let previous = meeting.previousReport else { return }
        meeting.summary = previous.summary
        meeting.coaching = previous.coaching
        meeting.reportTemplateData = previous.templateData
        if let id = previous.profileID {
            let found = try? modelContext?.fetch(FetchDescriptor<CallProfile>(predicate: #Predicate { $0.id == id })).first
            if let found { meeting.profile = found }
        } else {
            meeting.profile = nil
        }
        meeting.previousReportData = nil
        try? modelContext?.save()
        await memory.index(meeting)
    }
}
