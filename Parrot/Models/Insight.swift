import Foundation
import SwiftData

/// A single piece of live call intelligence produced by the CallAnalysisEngine.
struct Insight: Identifiable, Equatable {
    let id = UUID()
    /// Stable kind key from the active profile (e.g. "suggestion", "objection",
    /// "reflection"). Styling is resolved from this key, never hardcoded.
    let kindKey: String
    let title: String
    let detail: String
    let callTime: TimeInterval
    let source: String?
    let createdAt = Date()
    var isHandled = false

    var style: KindStyle { KindResolver.fallbackStyle(forKey: kindKey) }

    var formattedCallTime: String {
        let minutes = Int(callTime) / 60
        let seconds = Int(callTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

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
        self.kindRaw = insight.kindKey
        self.title = insight.title
        self.detail = insight.detail
        self.callTime = insight.callTime
        self.source = insight.source
        self.isHandled = insight.isHandled
    }

    var style: KindStyle { KindResolver.fallbackStyle(forKey: kindRaw) }

    var formattedCallTime: String {
        let minutes = Int(callTime) / 60
        let seconds = Int(callTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
