import Foundation
import Observation

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
        case needsAPIKey
        case error(String)
    }

    private(set) var insights: [Insight] = []
    private(set) var status: Status = .off
    private(set) var isActive = false
    private(set) var sentiment: [String: Int] = [:]
    private(set) var sentimentRead: String?
    private(set) var activeProfile: CallProfile?

    /// Set by RecordingManager; supplies grounded references for suggestions.
    var knowledgeBase: KnowledgeBaseService?

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

    /// Wait this long after the latest segment before analyzing mid-flow speech.
    private let idleDebounce: TimeInterval = 8
    /// Detected questions only wait for the current transcription chunk to settle.
    private let questionDebounce: TimeInterval = 1
    /// Hard floor between two API calls so back-to-back triggers don't spam.
    private let minimumInterval: TimeInterval = 5
    /// During continuous speech every segment resets the idle debounce, which would
    /// starve analysis forever — never let unanalyzed speech wait longer than this.
    private let maximumStaleness: TimeInterval = 15

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
        meCharacters = 0
        themCharacters = 0
        sentiment = [:]; sentimentRead = nil
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
        guard isActive, segments.count > lastAnalyzedCount else { return }

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

        // Last ~2 minutes of context keeps calls fast and cheap.
        let window = segments.suffix(60)
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
            gauges: profile?.gauges ?? []
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
            let existingTitles = Set(insights.map { $0.title.lowercased() })
            let unique = result.insights
                .filter { !existingTitles.contains($0.title.lowercased()) }
                .map { Insight(kindKey: $0.kindKey, title: $0.title, detail: $0.detail, callTime: anchorTime, source: $0.source) }
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
