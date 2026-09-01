import Foundation
import Observation

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

    /// (question fast-track, idle debounce, floor between calls, staleness cap).
    /// Fast MUST stay identical to the original constants — untouched users
    /// get untouched behavior. The other rows are first guesses; tune here.
    var timing: (question: TimeInterval, idle: TimeInterval, floor: TimeInterval, staleness: TimeInterval) {
        switch self {
        case .fast: (1, 8, 5, 15)
        case .balanced: (3, 15, 20, 45)
        case .relaxed: (10, 30, 60, 120)
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
    /// Live translation target. Re-read each pass so a mid-call language switch
    /// is on the next copilot request.
    var translationContext: (() -> TranslationContext?)?

    let provider: AnalysisProvider
    private var callBrief = ""
    private var segments: [(time: TimeInterval, text: String, source: AudioSource)] = []
    private var meCharacters = 0
    private var themCharacters = 0
    private var lastAnalyzedCount = 0
    private var debounceTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var lastAnalysisEnd = Date.distantPast
    private var rerunRequested = false
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

    init(provider: AnalysisProvider = ClaudeAnalysisProvider()) {
        self.provider = provider
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "copilotEnabled")
    }

    func start(profile: CallProfile?, brief: String = "") {
        guard isEnabled else {
            status = .off
            return
        }
        insights = []
        segments = []
        lastAnalyzedCount = 0
        rerunRequested = false
        oldestPendingSince = nil
        isPaused = false
        meCharacters = 0
        themCharacters = 0
        sentiment = [:]; sentimentRead = nil; coachLine = nil
        activeProfile = profile
        callBrief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        isActive = true
        status = provider.isConfigured ? .listening : .needsAPIKey
    }

    func stop() {
        isActive = false
        debounceTask?.cancel()
        debounceTask = nil
        analysisTask?.cancel()
        analysisTask = nil
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
        let isUrgent = source == .them && Self.looksLikeQuestion(text)
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

        let wait = minimumInterval - Date.now.timeIntervalSince(lastAnalysisEnd)
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
        let knownTitles = insights.prefix(20).map(\.title)
        let anchorTime = window.last?.time ?? 0

        // Retrieve knowledge base material matching the most recent speech.
        let query = segments.suffix(8).map(\.text).joined(separator: " ")
        let references = await knowledgeBase?.search(query: query, profileID: profile?.id) ?? []

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
            translation: translationContext?()
        )

        do {
            let result = try await provider.analyze(request)
            guard isActive, !Task.isCancelled else {
                if !Task.isCancelled { analysisTask = nil }
                return
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
            let openInsights = insights.filter { !$0.isHandled }
            let unique = result.insights
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
                .map { Insight(kindKey: $0.kindKey, title: $0.title, detail: $0.detail, callTime: anchorTime, source: $0.source, reply: $0.reply) }
            insights.insert(contentsOf: unique, at: 0)
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
                         meCharacters: Int, themCharacters: Int) {
        activeProfile = profile
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

    /// Marks a pinned blocker as handled; it moves from the pinned zone into the feed.
    func markHandled(_ insight: Insight) {
        guard let index = insights.firstIndex(where: { $0.id == insight.id }) else { return }
        insights[index].isHandled = true
    }

    func dismiss(_ insight: Insight) {
        insights.removeAll { $0.id == insight.id }
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

    /// Cheap detector that fast-tracks analysis when someone asks something.
    static func looksLikeQuestion(_ text: String) -> Bool {
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
