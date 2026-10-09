import Foundation

/// The maths behind the report's "How the call went" card, kept apart from
/// SwiftUI so `--profile-test` can check it.
enum ToneTimeline {
    /// A gauge move this big between two Copilot passes is a turning point in
    /// the report and a mood-shift nudge live: the same test, so both agree.
    static let turnThreshold = 25

    struct Span: Equatable {
        var isMe: Bool
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var words: Int { text.split(whereSeparator: \.isWhitespace).count }
    }

    struct Minute: Equatable {
        var me: TimeInterval = 0
        var them: TimeInterval = 0
    }

    struct MoodPoint: Equatable {
        var time: TimeInterval
        var value: Int
    }

    struct TurningPoint: Equatable {
        var time: TimeInterval
        var from: Int
        var to: Int
        var text: String
        var quote: String?
    }

    struct Moment: Identifiable, Equatable {
        enum Kind: Equatable { case nudge(Nudge.Kind), turn, mark }
        var id: Int { number }
        var number: Int
        var time: TimeInterval
        var kind: Kind
        var title: String
        var detail: String
    }

    /// Everything the card draws.
    struct Model: Equatable {
        var duration: TimeInterval
        var minutes: [Minute]
        var talkPercentMe: Int?
        var gauge: SentimentGauge?
        var mood: [MoodPoint]
        var endLevel: String?
        var moments: [Moment]
    }

    static func spans(_ segments: [TranscriptSegment]) -> [Span] {
        segments.map { Span(isMe: $0.speakerLabel == "Me", start: $0.startTime, end: $0.endTime, text: $0.text) }
    }

    /// Seconds of speech per minute of the call, you vs them.
    static func talkByMinute(_ spans: [Span], duration: TimeInterval) -> [Minute] {
        let count = max(1, Int((duration / 60).rounded(.up)))
        var minutes = Array(repeating: Minute(), count: count)
        for span in spans where span.end > span.start {
            var t = span.start
            while t < span.end {
                let index = min(count - 1, max(0, Int(t / 60)))
                let edge = index == count - 1 ? span.end : min(span.end, Double(index + 1) * 60)
                if span.isMe { minutes[index].me += edge - t } else { minutes[index].them += edge - t }
                t = edge
            }
        }
        return minutes
    }

    /// Your share of the speaking time, nil when nobody spoke. Seconds, not
    /// words, so a Turkish call isn't under-counted.
    static func talkPercentMe(_ spans: [Span]) -> Int? {
        let me = spans.filter(\.isMe).reduce(0) { $0 + max(0, $1.end - $1.start) }
        let total = spans.reduce(0) { $0 + max(0, $1.end - $1.start) }
        return total > 0 ? Int((me / total * 100).rounded()) : nil
    }

    /// The gauge the timeline draws: the first that isn't the talk balance
    /// (the bars already show that).
    static func mainGauge(_ gauges: [SentimentGauge]) -> SentimentGauge? {
        gauges.first { $0.key != "my_dominance" }
    }

    /// A 0-100 reading in the gauge's own words.
    static func level(_ value: Int, _ gauge: SentimentGauge) -> String {
        value <= 33 ? gauge.lowLabel : value >= 67 ? gauge.highLabel : "In between"
    }

    /// The line most likely behind a change between two passes: the wordiest
    /// one that ended in (after, upTo]. "Okay" is rarely the reason.
    static func cause(_ spans: [Span], after: TimeInterval, upTo: TimeInterval) -> Span? {
        spans.filter { $0.end > after && $0.end <= upTo }.max { $0.words < $1.words }
    }

    /// The first Copilot pass can come back all zeros (no evidence yet). That
    /// is no reading, not the lowest one: dropped when read, so saved calls are fixed too.
    static func readings(_ snapshots: [MoodSnapshot]) -> [MoodSnapshot] {
        Array(snapshots.drop { $0.values.values.allSatisfy { $0 == 0 } })
    }

    static func turningPoints(_ snapshots: [MoodSnapshot], gauge: SentimentGauge, spans: [Span]) -> [TurningPoint] {
        let points = snapshots.compactMap { s in s.values[gauge.key].map { MoodPoint(time: s.time, value: $0) } }
        return zip(points, points.dropFirst()).compactMap { a, b in
            // Early passes are guesses on a few lines; live mood shifts wait out the warm-up too.
            guard b.time >= NudgeDetector.Tuning.warmUp, abs(b.value - a.value) >= turnThreshold else { return nil }
            let line = cause(spans, after: a.time, upTo: b.time)
            return TurningPoint(time: line?.start ?? b.time, from: a.value, to: b.value,
                                text: shiftText(gauge, rising: b.value > a.value, quote: line?.text),
                                quote: line?.text)
        }
    }

    /// "Frustration moved toward Upset after “we can't do that date”".
    static func shiftText(_ gauge: SentimentGauge, rising: Bool, quote: String?) -> String {
        let text = "\(gauge.label) moved toward \(rising ? gauge.highLabel : gauge.lowLabel)"
        guard let quote else { return text }
        return text + " after \u{201C}\(NudgeDetector.short(quote))\u{201D}"
    }

    static func moments(nudges: [Nudge], turns: [TurningPoint], marks: [Bookmark]) -> [Moment] {
        var raw: [(time: TimeInterval, kind: Moment.Kind, title: String, detail: String)] = []
        for n in nudges { raw.append((n.time, .nudge(n.kind), n.kind.title, n.text)) }
        for t in turns where !nudges.contains(where: { $0.kind == .moodShift && abs($0.time - t.time) < 1 }) {
            raw.append((t.time, .turn, "Turning point", t.text))
        }
        for m in marks { raw.append((m.time, .mark, "You marked this", m.label.isEmpty ? "A moment you marked" : m.label)) }
        return raw.sorted { $0.time < $1.time }.enumerated().map { i, r in
            Moment(number: i + 1, time: r.time, kind: r.kind, title: r.title, detail: r.detail)
        }
    }

    /// nil when there's no two-sided call to show (imported audio has no "Me").
    static func model(duration: TimeInterval, spans: [Span], nudges: [Nudge],
                      timeline: MoodTimeline?, marks: [Bookmark]) -> Model? {
        guard spans.contains(where: \.isMe), spans.contains(where: { !$0.isMe }) else { return nil }
        let length = max(duration, spans.map(\.end).max() ?? 0)
        let gauge = timeline.flatMap { mainGauge($0.gauges) }
        let snapshots = readings(timeline?.snapshots ?? [])
        let mood = gauge.map { g in
            snapshots.compactMap { s in s.values[g.key].map { MoodPoint(time: s.time, value: $0) } }
        } ?? []
        let turns = gauge.map { turningPoints(snapshots, gauge: $0, spans: spans) } ?? []
        return Model(duration: length, minutes: talkByMinute(spans, duration: length),
                     talkPercentMe: talkPercentMe(spans), gauge: mood.isEmpty ? nil : gauge, mood: mood,
                     endLevel: gauge.flatMap { g in mood.last.map { level($0.value, g) } },
                     moments: moments(nudges: nudges, turns: turns, marks: marks))
    }
}
