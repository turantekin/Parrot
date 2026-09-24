import Foundation

/// A moment the user marked during (or after) a call: "this bit matters".
/// Stored as JSON on `Meeting.bookmarksData`; feeds the report prompt, the
/// report's "Moments you marked" card and the transcript.
struct Bookmark: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// Call time in seconds, same clock as `TranscriptSegment.startTime`.
    var time: TimeInterval
    /// Optional short label ("pricing question"); empty means unlabeled.
    var label: String = ""

    /// Labels are typed by the user and later sent to the report model, so
    /// keep them to one short line.
    static let maxLabelLength = 120

    static func cleanLabel(_ raw: String) -> String {
        let oneLine = raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(oneLine.prefix(maxLabelLength))
    }

    /// Two marks this close together are one moment — a double-press of the
    /// hotkey (or the hotkey and the menu firing together) must not duplicate.
    static let mergeWindow: TimeInterval = 2

    /// `existing` plus a new mark at `time`, unless one already sits within
    /// `mergeWindow` (then nil: nothing to add). Result stays time-sorted.
    static func adding(_ time: TimeInterval, label: String = "",
                       to existing: [Bookmark]) -> (all: [Bookmark], added: Bookmark)? {
        guard time.isFinite, time >= 0 else { return nil }
        if existing.contains(where: { abs($0.time - time) < mergeWindow }) { return nil }
        let mark = Bookmark(time: time, label: cleanLabel(label))
        return ((existing + [mark]).sorted { $0.time < $1.time }, mark)
    }

    /// Prompt line for the report model: "[12:34] pricing question".
    var promptLine: String {
        let stamp = Receipts.stamp(time)
        return label.isEmpty ? "[\(stamp)]" : "[\(stamp)] \(label)"
    }
}
