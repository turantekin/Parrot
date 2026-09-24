import Foundation
import Observation
import os

/// How eagerly the copilot calls the model. One knob instead of four raw
/// timers: Fast is the original always-on behavior; Relaxed spaces requests
/// out to roughly one per minute so free-tier rate limits survive a whole
/// meeting. Persisted in UserDefaults ("copilotPace"), read live so a
/// mid-call settings change applies immediately.
enum CopilotPace: String, CaseIterable, Identifiable {
    case fast, balanced, relaxed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .relaxed: "Relaxed"
        }
    }

    /// Plain-words tradeoff, shown under the Settings picker.
    var caption: String {
        switch self {
        case .fast: "Tips arrive within seconds. Most requests, highest cost."
        case .balanced: "A couple of requests per minute."
        case .relaxed: "Fewest requests — fits free-model limits. Tips can arrive up to a minute late."
        }
    }

    /// (question fast-track debounce, idle debounce, floor between calls,
    /// staleness cap, question floor). Idle/floor/staleness on Fast are the
    /// original constants. The question floor is the shorter wait a "Them"
    /// question gets instead of the full floor: it keeps the single-in-flight
    /// rule and still caps calls per minute, which "bypass the floor" would
    /// not. The question debounce is short everywhere because utterances are
    /// already silence-bound: a question is almost always one segment, and the
    /// next one cannot land for well over a second.
    var timing: (question: TimeInterval, idle: TimeInterval, floor: TimeInterval,
                 staleness: TimeInterval, questionFloor: TimeInterval) {
        switch self {
        case .fast: (0.3, 8, 5, 15, 2)
        case .balanced: (1, 15, 20, 45, 5)
        case .relaxed: (3, 30, 60, 120, 15)
        }
    }

    static var selected: CopilotPace {
        CopilotPace(rawValue: UserDefaults.standard.string(forKey: "copilotPace") ?? "") ?? .fast
    }
}

/// How much recent conversation each live request carries. Cards are always
/// sent and act as the call's long-term memory, so old transcript text mostly
/// adds cost and latency, not insight. Persisted as "copilotWindow".
enum CopilotWindow: String, CaseIterable, Identifiable {
    case recent, standard, long

    var id: String { rawValue }

    var minutes: Int {
        switch self {
        case .recent: 2
        case .standard: 5
        case .long: 10
        }
    }

    var label: String {
        switch self {
        case .recent: "Recent — last 2 minutes"
        case .standard: "Standard — last 5 minutes"
        case .long: "Long — last 10 minutes"
        }
    }

    static var selected: CopilotWindow {
        CopilotWindow(rawValue: UserDefaults.standard.string(forKey: "copilotWindow") ?? "") ?? .standard
    }
}

/// Always-on copilot loop: watches the live transcript for the whole call and pushes
/// insights (suggested answers, blockers, action items) as the conversation unfolds.
///
/// Triggering is event-driven, not a fixed poll: a detected question fires analysis
/// almost immediately, while mid-flow speech waits for a natural pause. A minimum
/// interval between API calls keeps cost and card-churn under control.
@MainActor
@Observable
final class CallAnalysisEngine {
    enum Status: Equatable {
        case off
        case listening
        case analyzing
        case paused
        case needsAPIKey
        case error(String)
    }

    private(set) var insights: [Insight] = []
    private(set) var status: Status = .off
    private(set) var isActive = false
    private(set) var sentiment: [String: Int] = [:]
    private(set) var sentimentRead: String?
    /// One-sentence live-coaching verdict from the latest pass — drives the
    /// always-on coach card ("Going well — now ask who signs off.").
    private(set) var coachLine: String?
    private(set) var activeProfile: CallProfile?

    /// Overall 0-100 "how is this call going" from the latest pass.
    var callScore: Int? { sentiment["score"] }

    /// Set by RecordingManager; supplies grounded references for suggestions.
    var knowledgeBase: KnowledgeBaseService?

    let provider: AnalysisProvider
    /// The user's one-liner for this call; the prompt carries it as "Brief for this specific call".
    private(set) var callBrief = ""
    /// The matched calendar invite, when the user shares it with the copilot
    /// (see AnalysisRequest.calendarContext).
    private(set) var calendarContext = ""
    private var segments: [(time: TimeInterval, text: String, source: AudioSource)] = []
    private var meCharacters = 0
    private var themCharacters = 0
    private var lastAnalyzedCount = 0
    private var debounceTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var lastAnalysisEnd = Date.distantPast
    private var rerunRequested = false
    /// A "Them" question arrived since the last scheduled run: the next run
    /// waits the short question floor. Survives a queued rerun.
    private var pendingUrgent = false
    private var oldestPendingSince: Date?

    /// Timing now comes from the user's pace choice (Settings → Copilot).
    /// Roles unchanged: idle = wait after the latest mid-flow segment,
    /// question = fast-track for the other side's questions, floor = hard
    /// minimum between two API calls, staleness = never let unanalyzed speech
    /// wait longer than this even during continuous talk.
    private var idleDebounce: TimeInterval { CopilotPace.selected.timing.idle }
    private var questionDebounce: TimeInterval { CopilotPace.selected.timing.question }
    private var minimumInterval: TimeInterval { CopilotPace.selected.timing.floor }
    private var maximumStaleness: TimeInterval { CopilotPace.selected.timing.staleness }
    private var questionFloor: TimeInterval { CopilotPace.selected.timing.questionFloor }

    init(provider: AnalysisProvider = ClaudeAnalysisProvider()) {
        self.provider = provider
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "copilotEnabled")
    }

    func start(profile: CallProfile?, brief: String = "", calendarContext: String = "") {
        guard isEnabled else {
            status = .off
            return
        }
        insights = []
        segments = []
        lastAnalyzedCount = 0
        rerunRequested = false
        pendingUrgent = false
        oldestPendingSince = nil
        fastTask?.cancel()
        fastTask = nil
        pendingExcerpts = []
        consecutiveFastFailures = 0
        fastPathPausedUntil = .distantPast
        fastPathLastError = nil
        fastPathStats = (0, 0, 0)
        isPaused = false
        meCharacters = 0
        themCharacters = 0
        sentiment = [:]; sentimentRead = nil; coachLine = nil
        activeProfile = profile
        callBrief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        self.calendarContext = calendarContext
        isActive = true
        status = provider.isConfigured ? .listening : .needsAPIKey
        // Open the TLS connection now so the first excerpt does not pay it.
        if fastPathAvailable { docMatcher?.warmUp() }
    }

    func stop() {
        isActive = false
        debounceTask?.cancel()
        debounceTask = nil
        analysisTask?.cancel()
        analysisTask = nil
        fastTask?.cancel()
        fastTask = nil
        pendingExcerpts = []
        status = .off
    }

    /// Mid-call switch, distinct from stop()/start(): cards, counters, and the
    /// collected transcript all survive. While paused, speech keeps
    /// accumulating (so the model has context on resume) but nothing is
    /// scheduled and nothing is sent. Resume analyzes the backlog promptly —
    /// still behind the pace floor, so it can't burst.
    private(set) var isPaused = false

    func setPaused(_ paused: Bool) {
        guard isActive, paused != isPaused else { return }
        isPaused = paused
        if paused {
            debounceTask?.cancel()
            debounceTask = nil
            oldestPendingSince = nil  // paused time must not count as staleness
            status = .paused
        } else {
            status = provider.isConfigured ? .listening : .needsAPIKey
            if segments.count > lastAnalyzedCount {
                oldestPendingSince = .now
                triggerAnalysis()
            }
        }
    }

    /// Share of the conversation spoken by the user, once there's enough signal.
    var userTalkPercent: Int? {
        let total = meCharacters + themCharacters
        guard total >= 400 else { return nil }
        return Int((Double(meCharacters) / Double(total) * 100).rounded())
    }

    /// Feed every finalized transcript segment here. The engine decides when to analyze.
    func ingest(text: String, at time: TimeInterval, source: AudioSource) {
        guard isActive, isEnabled else { return }
        guard provider.isConfigured else {
            status = .needsAPIKey
            return
        }

        segments.append((time, text, source))
        switch source {
        case .me: meCharacters += text.count
        case .them: themCharacters += text.count
        }

        // Paused: collect context, schedule nothing. setPaused(false) picks
        // the backlog up.
        guard !isPaused else { return }

        if oldestPendingSince == nil {
            oldestPendingSince = .now
        }

        // Only the other side's questions get the fast track — the user's own
        // questions don't need an instant suggested answer.
        let isUrgent = source == .them && Self.isSubstantiveQuestion(text)
        if isUrgent {
            pendingUrgent = true
            Self.log.notice("question at \(time, format: .fixed(precision: 1), privacy: .public)s: \(text.prefix(80), privacy: .public)")
        }

        if isUrgent, fastPathAvailable {
            // Fork the Jev fast path here, before any debounce: this is the one
            // place that sees "Them + question" first, and it never touches the
            // Haiku cadence below. The previous line or two disambiguate a
            // follow-up ("and for express?").
            let before = segments.dropLast().suffix(2)
                .map { "\($0.source.label): \($0.text)" }.joined(separator: "\n")
            fastTask?.cancel()
            fastTask = Task { [weak self] in
                await self?.fastDocAnswer(question: text, before: before, at: time)
            }
        }

        var delay = isUrgent ? questionDebounce : idleDebounce
        if let pendingSince = oldestPendingSince {
            let remainingBudget = max(0, maximumStaleness - Date.now.timeIntervalSince(pendingSince))
            delay = min(delay, remainingBudget)
        }

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.triggerAnalysis()
        }
    }

    // MARK: - Analysis

    private func triggerAnalysis() {
        // The pause guard also covers the rerun path out of runAnalysis: a
        // rerun queued before pausing must not fire during the pause.
        guard isActive, !isPaused, segments.count > lastAnalyzedCount else { return }

        // One call in flight at a time; queue a rerun so new context isn't dropped.
        if analysisTask != nil {
            rerunRequested = true
            return
        }

        // A question waits the short question floor, never the full one; the
        // flag survives a queued rerun so a mid-call question keeps its lane.
        let floor = pendingUrgent ? questionFloor : minimumInterval
        pendingUrgent = false
        let wait = floor - Date.now.timeIntervalSince(lastAnalysisEnd)
        analysisTask = Task { [weak self] in
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
            }
            guard !Task.isCancelled else { return }
            await self?.runAnalysis()
        }
    }

    private func runAnalysis() async {
        // A cancelled run must touch nothing: stop() may already have been
        // followed by a new start(), so isActive alone can't distinguish "this
        // session" from "the next one" — inserting stale insights or nil-ing the
        // new session's task handle would corrupt the new call.
        guard isActive, !Task.isCancelled else {
            if !Task.isCancelled { analysisTask = nil }
            return
        }

        let profile = activeProfile
        // An empty kind list can't produce a valid schema ("enum": [] is a 400
        // on every call) — surface it once instead of erroring forever.
        guard !(profile?.kinds ?? []).isEmpty else {
            status = .error("This profile has no insight kinds — add one in Settings → Profiles.")
            analysisTask = nil
            return
        }

        status = .analyzing
        // Remember the window bounds so a failed call can re-arm them — otherwise
        // a transient error permanently skips this speech (no retry ever fires
        // until new speech arrives).
        let previousAnalyzedCount = lastAnalyzedCount
        let previousPendingSince = oldestPendingSince
        lastAnalyzedCount = segments.count
        oldestPendingSince = nil

        // Time-based context window (Settings → Copilot). The old fixed
        // "last 60 lines" quietly grew when segmentation made lines
        // utterance-sized; minutes are the unit that stays honest.
        let take = Self.windowSuffixCount(
            times: segments.map(\.time),
            seconds: TimeInterval(CopilotWindow.selected.minutes * 60))
        let window = segments.suffix(take)
        let transcript = window
            .map { "\($0.source.label): \($0.text)" }
            .joined(separator: "\n")
        // Excerpts are not model insights: listing one as "already shown"
        // would make Haiku skip the very question it answers.
        let knownTitles = insights.filter { $0.kindKey != Insight.docExcerptKind }.prefix(20).map(\.title)
        let anchorTime = window.last?.time ?? 0

        // Retrieve knowledge base material matching the most recent speech.
        // Two searches: the latest question from the other side leads (sharp,
        // and it is what the next card must answer; an 8-line window full of
        // small talk buried the pricing chunk in the 2026-09-19 live run), the
        // recent window fills the rest.
        let recent = segments.suffix(8)
        var references: [KBReference] = []
        if let kb = knowledgeBase {
            if let question = Self.latestQuestion(in: recent.map { ($0.text, $0.source) }) {
                references = await kb.search(query: question, profileID: profile?.id, topK: 2)
            }
            let windowQuery = recent.map(\.text).joined(separator: " ")
            for reference in await kb.search(query: windowQuery, profileID: profile?.id)
            where !references.contains(where: { $0.text == reference.text }) {
                references.append(reference)
            }
        }
        // Pin the chunks Jev picked since the last pass, so Haiku reasons over
        // the same evidence the user is already looking at (it only sees the
        // cosine top 4; Jev looked at 8).
        for pending in pendingExcerpts.reversed()
        where !references.contains(where: { $0.text == pending.chunk.text }) {
            references.insert(pending.chunk, at: 0)
        }

        let request = AnalysisRequest(
            transcript: transcript,
            knownInsightTitles: Array(knownTitles),
            references: references,
            instructions: profile?.tone ?? "",
            callBrief: callBrief,
            allowGeneralKnowledge: profile?.allowGeneralKnowledge ?? true,
            knownDocumentNames: profile.map { knowledgeBase?.documentNames(for: $0.id) ?? [] } ?? (knowledgeBase?.documents.map(\.name) ?? []),
            persona: profile?.persona ?? "",
            counterpart: profile?.counterpart ?? "the other person",
            kinds: profile?.kinds ?? [],
            gauges: profile?.gauges ?? [],
            calendarContext: calendarContext
        )

        do {
            let result = try await provider.analyze(request)
            guard isActive, !Task.isCancelled else {
                if !Task.isCancelled { analysisTask = nil }
                return
            }
            // Excerpts shown since the last pass: a grounded Haiku card on the
            // same question replaces them; otherwise they stay, still true.
            let shownExcerpts = pendingExcerpts
            pendingExcerpts = []
            for shown in shownExcerpts
            where Self.excerptSuperseded(question: shown.question, document: shown.chunk.documentName,
                                         by: result.insights) {
                insights.removeAll { $0.id == shown.id }
            }
            // Merge model sentiment; overlay the computed talk-balance gauge if present.
            var merged = result.sentiment
            if let pct = userTalkPercent, (profile?.gauges.contains { $0.key == "my_dominance" } ?? false) {
                merged["my_dominance"] = pct
            }
            sentiment = merged
            sentimentRead = result.read
            if let coach = result.coach { coachLine = coach }
            // The model says these already-shown items were since dealt with in
            // the conversation — clear them so stale alerts don't pile up (and
            // so the post-call report shows them Handled, not Unresolved).
            for title in result.resolved {
                let lowered = title.lowercased()
                if let idx = insights.firstIndex(where: { $0.title.lowercased() == lowered && !$0.isHandled }) {
                    insights[idx].isHandled = true
                }
            }
            let existingTitles = Set(insights.map { $0.title.lowercased() })
            // Beyond exact titles: drop reworded re-flags of an issue that is
            // still open. A real 11-min call produced TEN variants of the same
            // question ("…unknown", "…still unanswered", "…still live") —
            // prompt instructions alone don't stop it, so enforce it here.
            let openInsights = insights.filter { !$0.isHandled && $0.kindKey != Insight.docExcerptKind }
            let candidates = result.insights
                // The model's own dedup verdict: a non-empty "supersedes" means
                // it recognized the draft as an already-shown issue (any wording,
                // any kind). The 2026-07-17 call showed re-flags routinely cross
                // kinds (Shopify arrived as suggestion, then unanswered_question)
                // where no client-side text heuristic can safely judge — see the
                // calibration note on isNearDuplicate. The verdict is only
                // honored when corroborated, because a weak local model was
                // observed citing an unrelated card (dropping a genuinely new
                // insight is worse than letting one duplicate through).
                .filter { draft in
                    guard let claimed = draft.supersedes, !claimed.isEmpty else { return true }
                    return !Self.verdictCorroborated(
                        supersedes: claimed,
                        draftText: "\(draft.title) \(draft.detail)",
                        openCards: openInsights.map { ($0.title, "\($0.title) \($0.detail)") })
                }
                .filter { !existingTitles.contains($0.title.lowercased()) }
                .filter { draft in
                    !openInsights.contains { existing in
                        existing.kindKey == draft.kindKey && Self.isNearDuplicate(
                            "\(draft.title) \(draft.detail)",
                            "\(existing.title) \(existing.detail)")
                    }
                }
            // Cross-kind rewordings slip past everything above (the 2026-09-23
            // real call: eight cards on one worry across three kinds). Jev
            // judges each surviving draft against every open card in one
            // request; a draft goes when any pair reads as the same issue.
            // Fail-open: no key, no cards, or an error keeps every draft.
            var admitted = candidates
            if !candidates.isEmpty, !openInsights.isEmpty, fastPathAvailable, let matcher = docMatcher {
                let open = Array(openInsights.prefix(20))
                let pairs = candidates.flatMap { draft in
                    open.map { (a: "\(draft.title). \(draft.detail)", b: "\($0.title). \($0.detail)") }
                }
                if let scores = try? await matcher.sameIssue(pairs: pairs) {
                    guard isActive, !Task.isCancelled else {
                        if !Task.isCancelled { analysisTask = nil }
                        return
                    }
                    let keep = Self.dedupKeepMask(scores: scores, drafts: candidates.count,
                                                  open: open.count, threshold: Self.sameIssueThreshold)
                    for (index, draft) in candidates.enumerated() where !keep[index] {
                        Self.log.notice("dedup dropped [\(draft.kindKey, privacy: .public)] \(draft.title.prefix(80), privacy: .public)")
                    }
                    admitted = zip(candidates, keep).filter { $0.1 }.map { $0.0 }
                }
            }
            let unique = admitted.map { Insight(kindKey: $0.kindKey, title: $0.title, detail: $0.detail, callTime: anchorTime, source: $0.source, reply: $0.reply) }
            insights.insert(contentsOf: unique, at: 0)
            for inserted in unique {
                Self.log.notice("card [\(inserted.kindKey, privacy: .public)] \(inserted.title.prefix(80), privacy: .public)")
                onInsightInserted?(inserted)
            }
            status = .listening
        } catch let error as AnalysisError {
            if isActive, !Task.isCancelled {
                lastAnalyzedCount = previousAnalyzedCount
                oldestPendingSince = previousPendingSince
                if case .missingAPIKey = error {
                    status = .needsAPIKey
                } else {
                    status = .error(error.localizedDescription)
                }
            }
        } catch {
            if isActive, !Task.isCancelled {
                lastAnalyzedCount = previousAnalyzedCount
                oldestPendingSince = previousPendingSince
                status = .error(error.localizedDescription)
            }
        }

        // A cancelled task must not release the (possibly new) session's slot
        // or fire its rerun.
        guard !Task.isCancelled else { return }
        lastAnalysisEnd = .now
        analysisTask = nil

        if rerunRequested {
            rerunRequested = false
            triggerAnalysis()
        }
    }

    // MARK: - Snapshot Harness Support

    /// Dev-harness only: seed the engine with fake state so the copilot panel
    /// can be rendered offscreen (`--copilot-snapshot`) without a live call.
    func seedForSnapshot(profile: CallProfile?, insights: [Insight],
                         sentiment: [String: Int], read: String?, coach: String? = nil,
                         meCharacters: Int, themCharacters: Int, brief: String = "") {
        activeProfile = profile
        callBrief = brief
        self.insights = insights
        self.sentiment = sentiment
        sentimentRead = read
        coachLine = coach
        self.meCharacters = meCharacters
        self.themCharacters = themCharacters
        isActive = true
        status = .listening
    }

    // MARK: - Card Actions

    /// Replaces the brief mid-call. The next analysis request carries it; nothing is re-sent for it alone.
    func updateBrief(_ text: String) {
        callBrief = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Marks a pinned blocker as handled; it moves from the pinned zone into the feed.
    func markHandled(_ insight: Insight) {
        guard let index = insights.firstIndex(where: { $0.id == insight.id }) else { return }
        insights[index].isHandled = true
    }

    func dismiss(_ insight: Insight) {
        insights.removeAll { $0.id == insight.id }
        pendingExcerpts.removeAll { $0.id == insight.id }
    }

    // MARK: - Fast document answers (Jev)

    /// Timing trail for live tests: `log show --predicate 'subsystem == "com.uygar.parrot" AND category == "copilot"'`.
    /// Notice level so it persists (info-level lines were gone within the hour);
    /// public fields on purpose (NSLog from the sandboxed app is redacted); never key material.
    private static let log = Logger(subsystem: "com.uygar.parrot", category: "copilot")

    /// Set by RecordingManager. nil means the path does not exist for this call.
    var docMatcher: JevDocMatcher?
    /// Best-noul gate for showing an excerpt. Tuned by --doc-answer-eval on the
    /// 2026-09-19 label set (see docs/PERFORMANCE.md). Precision first.
    nonisolated static let docAnswerThreshold = 0.75
    /// Dev harness observation hook (--copilot-replay): every insertion, wall time.
    var onInsightInserted: ((Insight) -> Void)?
    private(set) var fastPathStats: (attempts: Int, hits: Int, failures: Int) = (0, 0, 0)
    private var fastTask: Task<Void, Never>?
    private var consecutiveFastFailures = 0
    /// Three failures in a row pause the path for a minute (a network blip
    /// must not cost the whole call); dev harnesses read the last reason.
    private var fastPathPausedUntil = Date.distantPast
    private(set) var fastPathLastError: String?
    /// Excerpts shown since the last Haiku pass: their chunk is pinned into
    /// Haiku's references, and a grounded Haiku card supersedes them.
    private var pendingExcerpts: [(id: UUID, chunk: KBReference, question: String)] = []

    /// Claude mode with a TypeSafe key and documents, and not in a failure
    /// cool-down. Ollama and custom stay local.
    private var fastPathAvailable: Bool {
        docMatcher?.isConfigured == true
            && CopilotProviderKind.selected == .claude
            && knowledgeBase.map { !$0.isEmpty } == true
            && Date.now >= fastPathPausedUntil
    }

    private func fastDocAnswer(question: String, before: String, at time: TimeInterval) async {
        guard let matcher = docMatcher, let kb = knowledgeBase else { return }
        fastPathStats.attempts += 1
        let refs = await kb.search(query: Self.fastPathQuery(question: question, before: before),
                                   profileID: activeProfile?.id, topK: JevDocMatcher.maxCandidates)
        guard !refs.isEmpty, isActive, !Task.isCancelled else { return }
        do {
            let scores = try await matcher.score(asked: question, before: before,
                                                 candidates: refs.map(\.text))
            guard isActive, !Task.isCancelled else { return }
            consecutiveFastFailures = 0
            guard let best = Self.bestCandidate(scores: scores, threshold: Self.docAnswerThreshold) else { return }
            let chunk = refs[best.index]
            let card = Insight(kindKey: Insight.docExcerptKind, title: Self.excerptTitle(for: question),
                               detail: Self.excerptDisplayText(chunk.text), callTime: time,
                               source: chunk.documentName)
            insights.insert(card, at: 0)
            pendingExcerpts.append((card.id, chunk, question))
            fastPathStats.hits += 1
            Self.log.notice("excerpt p=\(best.probability, format: .fixed(precision: 2), privacy: .public) from \(chunk.documentName, privacy: .public) for: \(question.prefix(80), privacy: .public)")
            onInsightInserted?(card)
        } catch {
            // Silent by design: Haiku is still coming. The panel never shows a
            // fast-path error; three in a row pause it for a minute.
            consecutiveFastFailures += 1
            fastPathStats.failures += 1
            fastPathLastError = error.localizedDescription
            Self.log.error("fast path failed: \(error.localizedDescription, privacy: .public)")
            if consecutiveFastFailures >= 3 {
                fastPathPausedUntil = Date.now.addingTimeInterval(60)
                consecutiveFastFailures = 0
            }
        }
    }

    nonisolated static func bestCandidate(scores: [Double], threshold: Double) -> (index: Int, probability: Double)? {
        guard let i = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[i] >= threshold else { return nil }
        return (i, scores[i])
    }

    /// The question as heard, quoted and capitalized, cut at a word under ~90 chars.
    nonisolated static func excerptTitle(for question: String) -> String {
        var q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = q.first { q = first.uppercased() + q.dropFirst() }
        if q.count > 90 {
            let cut = q.prefix(88)
            q = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "\u{2026}"
        }
        return "\u{201C}\(q)\u{201D}"
    }

    /// Chunks are Markdown; the card shows prose. Heading marks and bold
    /// markers go, table rows become "a · b" lines, rule rows vanish.
    nonisolated static func excerptDisplayText(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw -> String? in
            var line = String(raw)
            if line.hasPrefix("#") {
                line = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: "**", with: "")
            guard line.hasPrefix("|") else { return line }
            let cells = line.split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) { return nil }
            return cells.joined(separator: " · ")
        }.joined(separator: "\n")
    }

    /// A Haiku card supersedes an excerpt only when it is on the same topic
    /// (shares a stem with the question) AND is grounded: it cites the same
    /// document or carries a reply. Topic first, because with one big
    /// knowledge-base file every grounded card "cites the same document", and
    /// an unrelated pricing card would otherwise retire an eligibility excerpt.
    nonisolated static func excerptSuperseded(question: String, document: String, by drafts: [InsightDraft]) -> Bool {
        drafts.contains { draft in
            guard sharesTopicStem(question, "\(draft.title) \(draft.detail)") else { return false }
            let citesDocument = draft.source?.lowercased() == document.lowercased()
            return citesDocument || draft.reply?.nilIfEmpty != nil
        }
    }

    /// The document-search query for a question. A short follow-up ("Can I
    /// use your services?") carries no topic of its own, so the previous line
    /// from the other side is joined, minus its "Them: " label. Jev still gets
    /// the question and the context separately.
    nonisolated static func fastPathQuery(question: String, before: String) -> String {
        guard significantTokens(question).count < 4,
              let previous = before.split(separator: "\n").last.map(String.init) else { return question }
        let parts = previous.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let text = (parts.count == 2 ? String(parts[1]) : previous).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? question : text + " " + question
    }

    // MARK: - Heuristics

    /// How many trailing segments fall inside the live context window: every
    /// segment within `seconds` of the newest one, floored at `minCount` so a
    /// quiet call still sends something, capped at `maxCount` so a dense
    /// window can't balloon the payload. Pure so --profile-test drives it.
    /// Times are call-relative and appended in arrival order; the reverse scan
    /// stops at the first out-of-window segment, so a slightly out-of-order
    /// mic/system boundary line costs at most one segment either way.
    nonisolated static func windowSuffixCount(
        times: [TimeInterval], seconds: TimeInterval,
        minCount: Int = 10, maxCount: Int = 200
    ) -> Int {
        guard let newest = times.last else { return 0 }
        let cutoff = newest - seconds
        var count = 0
        for t in times.reversed() {
            guard t >= cutoff else { break }
            count += 1
        }
        return min(max(count, min(minCount, times.count)), maxCount)
    }

    /// Whether a model's "supersedes" claim holds up: the cited title must be a
    /// real open card, and the two texts must share at least one topic stem.
    /// Every true re-flag observed in the 2026-07-17 call shares one ("bank" /
    /// "banking", "shopify", "pricing" / "price"), while the hallucinated
    /// verdict a weak local model produced (EU-hosting card claiming to
    /// supersede the price card) shares none — that draft must survive.
    nonisolated static func verdictCorroborated(
        supersedes: String, draftText: String, openCards: [(title: String, text: String)]
    ) -> Bool {
        let claimed = supersedes.lowercased()
        guard let cited = openCards.first(where: { $0.title.lowercased() == claimed }) else {
            return false
        }
        return sharesTopicStem(draftText, cited.text)
    }

    /// True when any pair of significant tokens from the two texts shares a
    /// ≥4-character prefix — cheap morphology so "banking"/"bank" and
    /// "pricing"/"price" count as the same topic word.
    nonisolated static func sharesTopicStem(_ a: String, _ b: String) -> Bool {
        let ta = significantTokens(a), tb = significantTokens(b)
        return ta.contains { wa in
            tb.contains { wb in
                let n = min(4, min(wa.count, wb.count))
                return n >= 4 && wa.prefix(n) == wb.prefix(n)
            }
        }
    }

    /// Cheap "same issue, different words" check: significant-word overlap,
    /// normalized by the smaller set. Catches "Annual plan pricing—still
    /// unanswered" vs "What does the annual subscription cost?" while
    /// keeping genuinely distinct topics apart.
    ///
    /// Scope note (2026-08-01): this is deliberately the ONLY client-side text
    /// heuristic. Sentence-embedding distance (NLEmbedding, the KB's embedder)
    /// was calibrated against the real 2026-07-17 call and could not separate
    /// true re-flags from genuinely distinct cards — dup pairs scored 0.35–0.81
    /// while distinct pairs scored 0.32–0.70, overlapping almost entirely
    /// ("banking intro in your package?" vs "bank account setup" = 0.45, but
    /// buying-signal vs timeline-gap on the same launch = 0.66). Rewording that
    /// slips past this token check is handled model-side via the required
    /// "supersedes" field, which the engine filter above enforces.
    nonisolated static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let ta = significantTokens(a), tb = significantTokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        let overlap = Double(ta.intersection(tb).count)
        return overlap / Double(min(ta.count, tb.count)) >= 0.6
    }

    private nonisolated static let stopWords: Set<String> = [
        "the", "and", "for", "you", "your", "they", "their", "them",
        "what", "whats", "how", "does", "still", "with", "about",
        "from", "that", "this", "are", "isnt", "not", "have", "has",
        // Copilot-card boilerplate: these frame every card ("Prospect asked
        // whether…", "the user said…") and appear regardless of topic, so they
        // must never count as topic evidence.
        "prospect", "prospects", "asked", "asking", "asks", "whether", "said", "user",
    ]

    private nonisolated static func significantTokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopWords.contains($0) })
    }

    /// A question worth the fast lane: it reads like a question AND carries at
    /// least two content words. "Really?", "How are you?" and "Is it extra?"
    /// do not; "Do you take cards?" does. (2026-09-23 real call: greetings and
    /// one-word reactions were triggering document searches.)
    nonisolated static func isSubstantiveQuestion(_ text: String) -> Bool {
        looksLikeQuestion(text) && significantTokens(text).count >= 2
    }

    /// Same-issue gate for Jev's verdicts. On the 2026-09-23 real call every
    /// hand-labelled distinct pair scored 0.13 or less and the duplicates
    /// mostly 0.5 or more; the gap between is where this sits.
    nonisolated static let sameIssueThreshold = 0.5

    /// Which drafts survive Jev's same-issue verdicts, laid out draft-major
    /// (index = draft × open + card). A draft goes when any open card scores at
    /// or above the threshold. A short or missing answer keeps everything:
    /// dropping a real insight is worse than letting one duplicate through.
    nonisolated static func dedupKeepMask(scores: [Double], drafts: Int, open: Int, threshold: Double) -> [Bool] {
        guard drafts > 0, open > 0, scores.count == drafts * open else {
            return Array(repeating: true, count: max(0, drafts))
        }
        return (0..<drafts).map { draft in
            !(0..<open).contains { scores[draft * open + $0] >= threshold }
        }
    }

    /// The newest thing the other side asked in a window, if anything.
    nonisolated static func latestQuestion(in window: [(text: String, source: AudioSource)]) -> String? {
        window.last { $0.source == .them && looksLikeQuestion($0.text) }?.text
    }

    /// Cheap detector that fast-tracks analysis when someone asks something.
    nonisolated static func looksLikeQuestion(_ text: String) -> Bool {
        if text.contains("?") { return true }
        let lowered = text.lowercased()
        let openers = [
            "how much", "how many", "how do", "how does", "how long", "how soon",
            "can you", "could you", "can we", "could we", "can i", "could i",
            "what about", "what is", "what's", "what if", "what do", "what would",
            "do you", "would you", "will you", "did you", "are you", "have you",
            "is there", "are there", "is it", "does it", "will it",
            "when can", "when do", "when will", "where do", "who is", "who's",
            "why ", "tell me about",
        ]
        return openers.contains { lowered.contains($0) }
    }
}
