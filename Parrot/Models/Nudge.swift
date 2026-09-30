import Foundation

/// A live nudge: something measurable just happened in the call ("they've
/// gone quiet since you said …"). Saved on the meeting as JSON
/// (`Meeting.nudgesData`) so the report's tone timeline can show it.
struct Nudge: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        // Order = usefulness: when several are due at once, the first shows.
        case wrapUp, unansweredQuestion, goneQuiet, moodShift, talkingOver,
             repeatedPoint, longMonologue, shortAnswers, speedingUp

        var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }

        var title: String {
            switch self {
            case .wrapUp: "Wrap-up"
            case .unansweredQuestion: "Unanswered question"
            case .goneQuiet: "Gone quiet"
            case .moodShift: "Mood shift"
            case .talkingOver: "Talking over"
            case .repeatedPoint: "Repeated point"
            case .longMonologue: "Long monologue"
            case .shortAnswers: "Short answers"
            case .speedingUp: "Speeding up"
            }
        }

        var symbol: String {
            switch self {
            case .wrapUp: "checklist"
            case .unansweredQuestion: "questionmark.bubble"
            case .goneQuiet: "speaker.slash"
            case .moodShift: "chart.line.uptrend.xyaxis"
            case .talkingOver: "person.2.wave.2"
            case .repeatedPoint: "arrow.triangle.2.circlepath"
            case .longMonologue: "timer"
            case .shortAnswers: "text.badge.minus"
            case .speedingUp: "hare"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    /// Call time in seconds, same clock as `TranscriptSegment.startTime`.
    var time: TimeInterval
    var text: String
    var quote: String? = nil
    /// false: it came due while a rate limit held it back. It never showed
    /// live but still belongs on the report's timeline.
    var shown = true
}

/// The Copilot's gauge readings after one pass (key → 0-100).
struct MoodSnapshot: Codable, Hashable {
    var time: TimeInterval
    var values: [String: Int]
}

/// One call's gauge history, with the gauges it was read against so the
/// report can label it after the profile changes.
struct MoodTimeline: Codable, Equatable {
    var gauges: [SentimentGauge]
    var snapshots: [MoodSnapshot]
}
