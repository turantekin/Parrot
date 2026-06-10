import Foundation

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
    let createdAt = Date()
}
