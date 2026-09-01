import Foundation
import SwiftData

/// One finished dictation utterance, listed like a meeting.
@Model
final class DictationNote {
    var id: UUID
    var date: Date
    var text: String
    var duration: TimeInterval

    init(date: Date = .now, text: String, duration: TimeInterval = 0) {
        self.id = UUID()
        self.date = date
        self.text = text
        self.duration = duration
    }

    var title: String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return "Dictation" }
        return line.count > 48 ? String(line.prefix(48)) + "…" : line
    }
}
