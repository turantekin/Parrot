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

    private let provider: AnalysisProvider
    private var segments: [(time: TimeInterval, text: String)] = []
    private var lastAnalyzedCount = 0
    private var debounceTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var lastAnalysisEnd = Date.distantPast
    private var rerunRequested = false

    /// Wait this long after the latest segment before analyzing mid-flow speech.
    private let idleDebounce: Duration = .seconds(8)
    /// Detected questions only wait for the current transcription chunk to settle.
    private let questionDebounce: Duration = .seconds(1)
    /// Hard floor between two API calls so back-to-back triggers don't spam.
    private let minimumInterval: TimeInterval = 5

    init(provider: AnalysisProvider = ClaudeAnalysisProvider()) {
        self.provider = provider
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "copilotEnabled")
    }

    func start() {
        guard isEnabled else {
            status = .off
            return
        }
        insights = []
        segments = []
        lastAnalyzedCount = 0
        rerunRequested = false
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

    /// Feed every finalized transcript segment here. The engine decides when to analyze.
    func ingest(text: String, at time: TimeInterval) {
        guard isActive, isEnabled else { return }
        guard provider.isConfigured else {
            status = .needsAPIKey
            return
        }

        segments.append((time, text))

        let delay = Self.looksLikeQuestion(text) ? questionDebounce : idleDebounce
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
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
        guard isActive else {
            analysisTask = nil
            return
        }

        status = .analyzing
        lastAnalyzedCount = segments.count

        // Last ~2 minutes of context keeps calls fast and cheap.
        let window = segments.suffix(60)
        let transcript = window.map(\.text).joined(separator: "\n")
        let knownTitles = insights.prefix(20).map(\.title)

        do {
            let fresh = try await provider.analyze(
                transcript: transcript,
                knownInsightTitles: Array(knownTitles)
            )
            guard isActive else {
                analysisTask = nil
                return
            }
            let existingTitles = Set(insights.map { $0.title.lowercased() })
            let unique = fresh.filter { !existingTitles.contains($0.title.lowercased()) }
            insights.insert(contentsOf: unique, at: 0)
            status = .listening
        } catch let error as AnalysisError {
            if case .missingAPIKey = error {
                status = .needsAPIKey
            } else if isActive {
                status = .error(error.localizedDescription)
            }
        } catch {
            if isActive {
                status = .error(error.localizedDescription)
            }
        }

        lastAnalysisEnd = .now
        analysisTask = nil

        if rerunRequested {
            rerunRequested = false
            triggerAnalysis()
        }
    }

    // MARK: - Heuristics

    /// Cheap detector that fast-tracks analysis when someone asks something.
    static func looksLikeQuestion(_ text: String) -> Bool {
        if text.contains("?") { return true }
        let lowered = text.lowercased()
        let openers = [
            "how much", "how many", "how do", "how does", "can you", "could you",
            "what about", "what is", "what's", "do you", "would you", "is there",
            "when can", "why ",
        ]
        return openers.contains { lowered.contains($0) }
    }
}
