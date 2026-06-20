import Foundation

/// Exports meeting transcripts to TXT and SRT formats.
enum ExportService {

    // MARK: - Plain Text Export

    static func exportToTXT(meeting: Meeting) -> String {
        var output = """
        Meeting: \(meeting.title)
        Date: \(formatDate(meeting.date))
        Duration: \(meeting.formattedDuration)
        Speakers: \(meeting.speakerCount)

        """

        if let summary = meeting.summary {
            output += """

            === Summary ===

            \(summary)

            """
        }

        if let coaching = meeting.coaching {
            output += """

            === Coaching & Follow-ups ===

            \(coaching)

            """
        }

        if !meeting.insights.isEmpty {
            output += "\n=== Copilot Insights ===\n\n"
            for insight in meeting.sortedInsights {
                var line = "[\(insight.formattedCallTime)] \(insight.style.label): \(insight.title)"
                if insight.kindRaw == "blocker" {
                    line += insight.isHandled ? " (handled)" : " (UNRESOLVED)"
                }
                output += line + "\n"
                output += "    \(insight.detail)\n"
                if let source = insight.source {
                    output += "    Source: \(source)\n"
                }
            }
        }

        output += "\n=== Transcript ===\n\n"
        for segment in meeting.sortedSegments {
            let speaker = meeting.displayName(forSpeaker: segment.speakerLabel)
            output += "[\(segment.formattedTimestamp)] \(speaker): \(segment.text)\n"
        }

        return output
    }

    // MARK: - SRT Export

    static func exportToSRT(meeting: Meeting) -> String {
        var output = ""
        let segments = meeting.sortedSegments

        for (index, segment) in segments.enumerated() {
            let speaker = segment.speakerLabel != nil ? "[\(meeting.displayName(forSpeaker: segment.speakerLabel))] " : ""
            output += """
            \(index + 1)
            \(srtTimestamp(segment.startTime)) --> \(srtTimestamp(segment.endTime))
            \(speaker)\(segment.text)


            """
        }

        return output
    }

    // MARK: - Save to File

    static func save(content: String, filename: String, extension ext: String) throws -> URL {
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let url = downloadsDir.appendingPathComponent("\(filename).\(ext)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Helpers

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
