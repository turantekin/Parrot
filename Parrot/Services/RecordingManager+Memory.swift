import Foundation
import SwiftData

/// Meeting memory, Ask Parrot and the "last call" brief — kept beside
/// RecordingManager so the recording hub stays about recording.
extension RecordingManager {

    /// Runs once a meeting is `.done` (clean stop, recovery, import): index it
    /// for Ask Parrot, then the after-call actions the user switched on.
    func meetingFinished(_ meeting: Meeting) async {
        await memory.index(meeting)
        await afterCallActions(meeting)
    }

    /// Indexes finished meetings the memory hasn't seen (or that changed).
    func syncMemory() async {
        guard let modelContext else { return }
        let meetings = (try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? []
        await memory.sync(with: meetings)
    }

    /// The most recent earlier finished meeting with the same calendar series
    /// or a shared invitee.
    func previousMeeting(for meeting: Meeting, in context: ModelContext) -> Meeting? {
        let others = ((try? context.fetch(FetchDescriptor<Meeting>())) ?? [])
            .filter { $0.id != meeting.id && $0.status == .done }
        let candidates = others.map { m in
            LastCallBrief.Candidate(
                id: m.id, date: m.date, eventID: m.calendarEventID,
                emails: Set(m.attendees.compactMap(\.email)),
                names: Set(m.attendees.map(\.displayName) + Array(m.speakerNames.values)))
        }
        let id = LastCallBrief.previousMeeting(
            in: candidates, eventID: meeting.calendarEventID,
            emails: Set(meeting.attendees.compactMap(\.email)),
            names: Set(meeting.attendees.map(\.displayName)),
            before: meeting.date)
        return others.first { $0.id == id }
    }

    // MARK: - Ask Parrot

    /// Answers a question about past meetings. `scope` limits it to one
    /// meeting. Excerpts are found on the Mac; only when a reports brain is
    /// set up do the few best go to it for a written, cited answer. Private
    /// (on-device-only) meetings never go to a cloud brain.
    func ask(_ question: String, in chat: AskChat,
             progress: @MainActor (String) -> Void = { _ in }) async -> AskEngine.Result {
        let scope = chat.scope
        guard let modelContext else {
            return AskEngine.Result(lines: [], sources: [], refs: [], answeredByAI: false, note: nil)
        }
        // No full re-sync per question: meetings are indexed when they
        // finish, when their page closes after an edit, and at launch.
        let meetings = (try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? []
        let byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let switching = callAnalysisEngine.provider as? SwitchingAnalysisProvider
        let aiReady = switching?.askConfigured ?? callAnalysisEngine.provider.isConfigured
        // Decided once: whether the answer is written on this Mac. The same
        // decision filters private meetings AND routes the request below, so
        // the two can't disagree.
        let local = CloudGate.forcesLocal || (switching?.askRunsLocally ?? false)
        let excluded: Set<UUID> = local ? [] : Set(meetings.filter { !CloudGate.mayLeaveMac($0) }.map(\.id))

        // Ollama counts as set up whenever it's picked; check it's really
        // there before sending anything, so the user gets the fix, not a
        // connection error.
        var ollamaProblem: String?
        if aiReady, switching?.askUsesOllama == true {
            ollamaProblem = AskEngine.ollamaNote(installed: await OllamaProbe.installedModels(),
                                                 model: OpenAICompatibleProvider.ollamaModel)
        }
        let aiUsable = aiReady && ollamaProblem == nil

        progress("Reading your meetings…")
        let hits = await memory.search(question, within: scope.map { [$0] }, excluding: excluded, topK: 8)
        let meta = Dictionary(uniqueKeysWithValues: Set(hits.map(\.meetingID)).compactMap { id in
            byID[id].map { m in
                (id, (title: m.title, date: m.date,
                      people: m.attendees.map(\.displayName).filter { !$0.isEmpty }
                        + m.speakerNames.values.filter { !$0.isEmpty }))
            }
        })
        let (context, refs) = AskEngine.context(for: hits, meetings: meta)
        let privateNote = excluded.isEmpty ? nil
            : "On-device-only meetings aren't searched when the answer comes from a cloud AI."

        guard !hits.isEmpty else {
            return AskEngine.Result(lines: [AskEngine.Line(text: "Nothing in your meetings matches that yet.", citations: [])],
                                    sources: [], refs: [], answeredByAI: false, note: privateNote)
        }
        guard aiUsable else {
            return AskEngine.Result(lines: AskEngine.excerptLines(hits), sources: hits, refs: refs,
                                    answeredByAI: false,
                                    note: ollamaProblem ?? "Pick an AI at the top of this chat for written answers. These are the closest moments.")
        }

        progress("Writing…")
        do {
            let provider = callAnalysisEngine.provider
            let answer = try await CloudGate.$scopeLocal.withValue(local) {
                if let switching {
                    return try await switching.completeAsk(system: AskEngine.systemPrompt,
                        user: AskEngine.userContent(question: question, context: context), maxTokens: 700)
                }
                return try await provider.complete(system: AskEngine.systemPrompt,
                    user: AskEngine.userContent(question: question, context: context), maxTokens: 700)
            }
            let lines = AskEngine.parse(answer, refs: refs) { id, time in
                byID[id]?.receiptIndex.resolve(time) != nil
            }
            return AskEngine.Result(lines: lines, sources: hits, refs: refs, answeredByAI: true, note: privateNote,
                                    model: switching?.askModelLabel)
        } catch {
            return AskEngine.Result(lines: AskEngine.excerptLines(hits), sources: hits, refs: refs,
                                    answeredByAI: false,
                                    note: "The AI didn't answer (\(error.localizedDescription)). These are the closest moments.")
        }
    }
}
