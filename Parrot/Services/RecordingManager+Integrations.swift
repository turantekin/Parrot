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

    /// The transcript as the report prompts see it: "[mm:ss] Name: words".
    func promptTranscript(_ meeting: Meeting) -> String {
        meeting.sortedSegments
            .map { "[\($0.formattedTimestamp)] \(meeting.displayName(forSpeaker: $0.speakerLabel)): \($0.text)" }
            .joined(separator: "\n")
    }

    /// Whether this meeting may be sent to the reports brain as it's set up
    /// now: always when that brain is local, never for a private meeting on
    /// a cloud one.
    func reportsBrainAllowed(for meeting: Meeting) -> Bool {
        let switching = callAnalysisEngine.provider as? SwitchingAnalysisProvider
        return CloudGate.mayLeaveMac(meeting) || (switching?.reportsRunLocally ?? false)
    }

    /// Drafts (or redrafts) the follow-up email and stores it on the meeting.
    func draftFollowUp(_ meeting: Meeting) async throws {
        guard !meeting.segments.isEmpty else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "This meeting has no transcript."])
        }
        guard callAnalysisEngine.provider.isConfigured else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Set up the Copilot's AI in Settings first."])
        }
        guard reportsBrainAllowed(for: meeting) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey:
                "This meeting is on-device only. Draft its email with a local model (Ollama)."])
        }
        let people = meeting.attendees.map(\.displayName) + meeting.otherSpeakerLabels.compactMap { meeting.speakerNames[$0] }
        let draft = try await callAnalysisEngine.provider.complete(
            system: FollowUpEmail.systemPrompt,
            user: FollowUpEmail.userContent(
                transcript: promptTranscript(meeting),
                counterpart: meeting.profile?.counterpart ?? "the other person",
                people: Array(Set(people)).sorted(),
                nextSteps: LastCallBrief.openItems(summary: meeting.summary, coaching: meeting.coaching, limit: 12)),
            maxTokens: 900)
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
