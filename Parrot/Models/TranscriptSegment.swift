import Foundation
import SwiftData

@Model
final class TranscriptSegment {
    var id: UUID
    var meeting: Meeting?
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var speakerLabel: String?
    var confidence: Float?
    /// Target-language line. Empty when translation was off. Defaulted so
    /// older meetings migrate.
    var translation: String = ""

    init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        speakerLabel: String? = nil,
        confidence: Float? = nil
    ) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speakerLabel = speakerLabel
        self.confidence = confidence
    }

    var formattedTimestamp: String {
        let minutes = Int(startTime) / 60
        let seconds = Int(startTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
