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

    /// Answers a question in a chat. Follow-ups are rewritten into a
    /// standalone question before the on-Mac search; only the best passages
    /// and recent chat go to the Ask AI. Private (on-device-only) meetings
    /// never go to a cloud brain, and neither do earlier exchanges answered
    /// from them.
    func ask(_ question: String, in chat: AskChat,
             progress: @MainActor (String) -> Void = { _ in }) async -> AskEngine.Result {
        guard let modelContext else {
            return AskEngine.Result(lines: [], sources: [], refs: [], answeredByAI: false, note: nil)
        }
        let meetings = (try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? []
        let byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let switching = callAnalysisEngine.provider as? SwitchingAnalysisProvider
        let provider = callAnalysisEngine.provider
        let aiReady = switching?.askConfigured ?? provider.isConfigured
        // Decided once: whether the answer is written on this Mac. The same
        // decision filters private meetings, the history AND routes the
        // requests below, so they can't disagree.
        let local = CloudGate.forcesLocal || (switching?.askRunsLocally ?? false)
        let excluded: Set<UUID> = local ? [] : Set(meetings.filter { !CloudGate.mayLeaveMac($0) }.map(\.id))
        let history = AskEngine.history(chat.messages, cloud: !local)
        // Ollama counts as set up whenever it's picked; check it's really
        // there before sending anything (Task 5).
        var ollamaProblem: String?
        if aiReady, switching?.askUsesOllama == true {
            ollamaProblem = AskEngine.ollamaNote(installed: await OllamaProbe.installedModels(),
                                                 model: OpenAICompatibleProvider.ollamaModel)
        }
        let aiUsable = aiReady && ollamaProblem == nil

        func complete(_ system: String, _ user: String, _ maxTokens: Int) async throws -> String {
            try await CloudGate.$scopeLocal.withValue(local) {
                if let switching { return try await switching.completeAsk(system: system, user: user, maxTokens: maxTokens) }
                return try await provider.complete(system: system, user: user, maxTokens: maxTokens)
            }
        }

        progress("Reading your meetings…")
        // A follow-up is searched as a standalone question: the AI rewrites
        // it; without an AI (or on a bad reply) the previous question rides
        // along and the last answer's meetings are tried first.
        var searchQuestion = question
        var citedFirst: Set<UUID> = []
        if !history.isEmpty {
            if aiUsable,
               let reply = try? await complete(AskEngine.rewriteSystemPrompt,
                                               AskEngine.rewriteUser(history: history, question: question), 120),
               let standalone = AskEngine.parseRewrite(reply) {
                searchQuestion = standalone
            } else {
                let previous = chat.messages.last { $0.role == .me }?.text
                searchQuestion = AskEngine.localFollowUp(question: question, previousQuestion: previous)
                citedFirst = AskEngine.lastCited(chat.messages)
            }
        }

        let scope: Set<UUID>? = chat.scope.map { [$0] }
        var hits: [MemoryChunk] = []
        if !citedFirst.isEmpty {
            hits = await memory.search(searchQuestion, within: scope.map { $0.intersection(citedFirst) } ?? citedFirst,
                                       excluding: excluded, topK: 8)
        }
        if hits.isEmpty {
            hits = await memory.search(searchQuestion, within: scope, excluding: excluded, topK: 8)
        }

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
        let searchedFor = searchQuestion == question ? nil : searchQuestion
        let usedPrivate = local && hits.contains { byID[$0.meetingID].map { !CloudGate.mayLeaveMac($0) } ?? false }

        guard !hits.isEmpty else {
            return AskEngine.Result(lines: [AskEngine.Line(text: "Nothing in your meetings matches that yet.", citations: [])],
                                    sources: [], refs: [], answeredByAI: false, note: privateNote, searchedFor: searchedFor)
        }
        guard aiUsable else {
            return AskEngine.Result(lines: AskEngine.excerptLines(hits), sources: hits, refs: refs,
                                    answeredByAI: false,
                                    note: ollamaProblem ?? "Pick an AI at the top of this chat for written answers. These are the closest moments.",
                                    usedPrivate: usedPrivate, searchedFor: searchedFor)
        }

        progress("Writing…")
        do {
            let answer = try await complete(AskEngine.systemPrompt,
                                            AskEngine.answerUser(question: question, context: context, history: history), 700)
            let lines = AskEngine.parse(answer, refs: refs) { id, time in
                byID[id]?.receiptIndex.resolve(time) != nil
            }
            return AskEngine.Result(lines: lines, sources: hits, refs: refs, answeredByAI: true, note: privateNote,
                                    usedPrivate: usedPrivate, model: switching?.askModelLabel, searchedFor: searchedFor)
        } catch {
            return AskEngine.Result(lines: AskEngine.excerptLines(hits), sources: hits, refs: refs,
                                    answeredByAI: false,
                                    note: "The AI didn't answer (\(error.localizedDescription)). These are the closest moments.",
                                    usedPrivate: usedPrivate, searchedFor: searchedFor)
        }
    }
}
