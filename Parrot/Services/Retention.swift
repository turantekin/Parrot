import Foundation

/// Automatic clean-up: delete call audio (keeping transcript and report)
/// and/or whole meetings after a set number of days. Off by default; runs
/// at launch and hourly. Never touches a meeting that's still recording or
/// processing.
enum Retention {
    static let audioDaysKey = "retentionAudioDays"
    static let meetingDaysKey = "retentionMeetingDays"
    /// The choices Settings offers; 0 = keep forever.
    static let audioChoices = [0, 7, 30, 90, 365]
    static let meetingChoices = [0, 30, 90, 180, 365]

    struct Item {
        let id: UUID
        let date: Date
        let hasAudio: Bool
        let finished: Bool
    }

    /// What's due: meetings older than `meetingDays` go entirely; others
    /// older than `audioDays` lose their audio.
    static func due(_ items: [Item], now: Date, audioDays: Int, meetingDays: Int) -> (audio: [UUID], meetings: [UUID]) {
        let day: TimeInterval = 86_400
        var audio: [UUID] = []
        var meetings: [UUID] = []
        for item in items where item.finished {
            let age = now.timeIntervalSince(item.date)
            if meetingDays > 0, age > Double(meetingDays) * day {
                meetings.append(item.id)
            } else if audioDays > 0, item.hasAudio, age > Double(audioDays) * day {
                audio.append(item.id)
            }
        }
        return (audio, meetings)
    }

    static func label(days: Int) -> String {
        switch days {
        case 0: "Never"
        case 7: "After a week"
        case 30: "After 30 days"
        case 90: "After 90 days"
        case 180: "After 6 months"
        case 365: "After a year"
        default: "After \(days) days"
        }
    }
}
