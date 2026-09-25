import Foundation

/// After-call actions (folder export, follow-up email, webhook) and the
/// on-demand ones behind the meeting's Share menu.
extension RecordingManager {

    /// What the user switched on, run once per finished meeting. Failures are
    /// logged, never block the meeting.
    func afterCallActions(_ meeting: Meeting) async {
        if UserDefaults.standard.bool(forKey: ExportFolder.autoKey), ExportFolder.resolve() != nil {
            do { try ExportFolder.write(meeting) } catch {
                NSLog("Parrot: folder export failed, \(error.localizedDescription)")
            }
        }
        if UserDefaults.standard.bool(forKey: FollowUpEmail.autoKey), meeting.summary != nil,
           meeting.followUpEmail == nil {
            do { try await draftFollowUp(meeting) } catch {
                NSLog("Parrot: follow-up draft skipped, \(error.localizedDescription)")
            }
        }
        if UserDefaults.standard.bool(forKey: Webhook.enabledKey), CloudGate.mayLeaveMac(meeting) {
            do { try await Webhook.send(meeting) } catch {
                NSLog("Parrot: webhook failed, \(error.localizedDescription)")
            }
        }
    }

    /// Drafts (or redrafts) the follow-up email and stores it on the meeting.
    func draftFollowUp(_ meeting: Meeting) async throws {
        guard !meeting.segments.isEmpty else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "This meeting has no transcript."])
        }
        guard callAnalysisEngine.provider.isConfigured else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Set up the Copilot's AI in Settings first."])
        }
        let people = meeting.attendees.map(\.displayName) + meeting.otherSpeakerLabels.compactMap { meeting.speakerNames[$0] }
        let user = FollowUpEmail.userContent(
            transcript: meeting.promptTranscript,
            counterpart: meeting.profile?.counterpart ?? "the other person",
            people: Array(Set(people)).sorted(),
            nextSteps: LastCallBrief.openItems(summary: meeting.summary, coaching: meeting.coaching, limit: 12))
        // A private meeting's email is written by the local model, whatever
        // the reports brain is set to.
        let provider = callAnalysisEngine.provider
        let draft = try await CloudGate.$scopeLocal.withValue(!CloudGate.mayLeaveMac(meeting) || CloudGate.forcesLocal) {
            try await provider.complete(system: FollowUpEmail.systemPrompt, user: user, maxTokens: 900)
        }
        meeting.followUpEmail = draft
        try? modelContext?.save()
    }

    /// Next steps and commitments → Apple Reminders.
    func addNextStepsToReminders(_ meeting: Meeting) async throws -> Int {
        let items = LastCallBrief.openItems(summary: meeting.summary, coaching: meeting.coaching, limit: 20)
        guard !items.isEmpty else { return 0 }
        return try await reminders.add(items, from: meeting.title)
    }
}
