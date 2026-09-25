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
        let privateIDs = Set(meetings.filter { !CloudGate.mayLeaveMac($0) }.map(\.id))
        let excluded: Set<UUID> = local ? [] : privateIDs
        let history = AskEngine.history(chat.messages, cloud: !local, excluded: excluded)
        progress("Thinking…")
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

        // A follow-up is searched as a standalone question: the AI rewrites
        // it; without an AI (or on a bad reply) the previous question rides
        // along and the last answer's meetings are tried first.
        var searchQuestion = question
        var citedFirst: Set<UUID> = []
        // The AI said the follow-up stands on its own (SAME): a new topic.
        var newTopic = false
        if !history.isEmpty {
            if aiUsable,
               let reply = try? await complete(AskEngine.rewriteSystemPrompt,
                                               AskEngine.rewriteUser(history: history, question: question), 120),
               let standalone = AskEngine.parseRewrite(reply, original: question) {
                searchQuestion = standalone
                newTopic = standalone == question
            } else {
                let previous = chat.messages.last { $0.role == .me }?.text
                searchQuestion = AskEngine.localFollowUp(question: question, previousQuestion: previous)
                citedFirst = AskEngine.lastCited(chat.messages)
            }
        }

        // Date words only narrow a chat that searches everything — a chat
        // scoped to one meeting always searches that meeting, regardless of
        // what the question says about when.
        progress("Reading your meetings…")
        let range = AskEngine.dateRange(in: searchQuestion, now: .now)
        // "How many / longest / time in meetings": counted here, exactly,
        // with no AI and nothing sent anywhere.
        if chat.scope == nil, let mq = AskEngine.meetingQuestion(searchQuestion) {
            let done = meetings.filter { $0.status == .done && (range?.contains($0.date) ?? true) }
            let lines = AskEngine.meetingAnswer(mq.kind, turkish: mq.turkish,
                                                items: done.map { ($0.id, $0.title, $0.date, $0.duration) }, range: range)
            let cited = Set(lines.flatMap { $0.citations.map(\.meetingID) })
            let refs = done.filter { cited.contains($0.id) }.map {
                AskEngine.MeetingRef(ref: "", meetingID: $0.id, title: $0.title, date: $0.date, people: [])
            }
            return AskEngine.Result(lines: lines, sources: [], refs: refs, answeredByAI: true, note: nil,
                                    usedPrivate: done.contains { privateIDs.contains($0.id) },
                                    model: "Counted on this Mac",
                                    searchedFor: searchQuestion == question ? nil : searchQuestion)
        }
        let scope = AskEngine.searchScope(chatScope: chat.scope, range: range, meetings: meetings.map { ($0.id, $0.date) })
        // Rank wide, put the last answer's meetings first (follow-up
        // fallback), then cap below.
        func search(_ within: Set<UUID>?) async -> [MemoryChunk] {
            await memory.search(searchQuestion, within: within, excluding: excluded, topK: 36)
        }
        let all = await search(scope)
        let ranked = citedFirst.isEmpty ? all
            : AskEngine.citedFirst(await search(scope.map { $0.intersection(citedFirst) } ?? citedFirst), all, limit: 72)
        // A one-meeting chat gets that meeting's report plus up to 12
        // passages of it; a broad one at most 3 passages per meeting.
        let hits: [MemoryChunk]
        if let one = chat.scope {
            let report = excluded.contains(one) ? []
                : memory.chunks.filter { $0.meetingID == one && $0.kind == .report }
            hits = AskEngine.scopedHits(ranked, report: report)
        } else {
            hits = AskEngine.capped(ranked)
        }

        func people(_ m: Meeting) -> [String] {
            var seen = Set<String>()
            return (m.attendees.map(\.displayName) + m.speakerNames.values)
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        }
        let meta = Dictionary(uniqueKeysWithValues: Set(hits.map(\.meetingID)).compactMap { id in
            byID[id].map { m in (id, (title: m.title, date: m.date, people: people(m))) }
        })
        let (context, refs) = AskEngine.context(for: hits, meetings: meta)
        // A chat about all meetings also gets the list of them, for "how
        // many / how long / with whom" questions passages can't answer.
        let listed = chat.scope != nil ? [] : meetings.filter {
            $0.status == .done && !excluded.contains($0.id) && (range?.contains($0.date) ?? true)
        }
        let listItems = listed.map { ($0.title, $0.date, $0.duration, people($0)) }
        let meetingList = AskEngine.meetingList(listItems, limit: local ? 60 : 150)
        let meetingFacts = AskEngine.meetingFacts(listItems)
        let privateNote = AskEngine.privateNote(skipsPrivate: !excluded.isEmpty, messages: chat.messages)
        let searchedFor = searchQuestion == question ? nil : searchQuestion
        // ponytail: any private meeting in a local AI's list marks the answer
        // private (it could name it); per-line tracking if that over-marks.
        let usedPrivate = AskEngine.answerIsPrivate(hitMeetingIDs: Set(hits.map(\.meetingID) + listed.map(\.id)),
                                                    messages: chat.messages, privateIDs: privateIDs, local: local)

        // A count question can find no passages yet still be answered from the list.
        guard !hits.isEmpty || (aiUsable && !meetingList.isEmpty) else {
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
                                            AskEngine.answerUser(question: question, context: context,
                                                                 // A new topic gets no old answers to copy from.
                                                                 history: newTopic ? "" : history,
                                                                 meetingList: meetingList,
                                                                 facts: meetingFacts), 700)
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
