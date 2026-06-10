import Foundation
import SwiftData

/// A single piece of live call intelligence produced by the CallAnalysisEngine.
struct Insight: Identifiable, Equatable {
    enum Kind: String, Codable {
        case suggestion
        case blocker
        case actionItem = "action_item"
        case feedback
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String
    /// Seconds into the call of the speech that triggered this insight.
    let callTime: TimeInterval
    /// Knowledge base document the answer is grounded in, or "general knowledge".
    let source: String?
    let createdAt = Date()
    /// Blockers stay pinned until the user marks them handled.
    var isHandled = false

    var formattedCallTime: String {
        let minutes = Int(callTime) / 60
        let seconds = Int(callTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// Persisted copy of a live insight, attached to its meeting when recording stops.
@Model
final class CallInsight {
    var id: UUID
    var meeting: Meeting?
    var kindRaw: String
    var title: String
    var detail: String
    var callTime: TimeInterval
    var source: String?
    var isHandled: Bool

    init(from insight: Insight) {
        self.id = insight.id
        self.kindRaw = insight.kind.rawValue
        self.title = insight.title
        self.detail = insight.detail
        self.callTime = insight.callTime
        self.source = insight.source
        self.isHandled = insight.isHandled
    }

    var kind: Insight.Kind {
        Insight.Kind(rawValue: kindRaw) ?? .feedback
    }

    var formattedCallTime: String {
        let minutes = Int(callTime) / 60
        let seconds = Int(callTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
