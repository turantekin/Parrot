import Foundation

/// Decides when a live nudge is due ("they've gone quiet since you said …").
/// Pure: no audio, no UI, no clock of its own. `LiveNudgeSession` feeds it
/// finished lines, Copilot passes and the audio clock once a second;
/// `--profile-test` and `--nudge-replay` feed it scripted or saved calls.
/// Every nudge that comes due lands in `all` (the report's timeline);
/// `tick` returns the one to show now, if any.
struct NudgeDetector {
    struct Line: Equatable {
        var source: AudioSource
        var start: TimeInterval
        var end: TimeInterval
        var text: String
        var duration: TimeInterval { max(0, end - start) }
        var words: Int { text.split(whereSeparator: \.isWhitespace).count }
    }

    struct OpenQuestion: Equatable {
        var title: String
        var since: TimeInterval
    }

    /// One Copilot pass, as the detector needs it.
    struct Pass: Equatable {
        var time: TimeInterval
        /// Profile gauges only (key → 0-100).
        var values: [String: Int]
        var openQuestions: [OpenQuestion] = []
        /// Open pinned items (blockers and the like), by title.
        var openItems: [String] = []
        var wrappingUp = false
        var nextStepAgreed = false
    }

    /// Starting values; tune with `--nudge-replay` on real calls.
    enum Tuning {
        static let warmUp: TimeInterval = 120
        static let minGap: TimeInterval = 120
        static let sameKindGap: TimeInterval = 300
        static let quietFloor: TimeInterval = 6
        static let quietFactor = 3.0
        static let typicalReplyGap: TimeInterval = 1.5
        static let monologue: TimeInterval = 90
        static let talkOverWindow: TimeInterval = 300
        static let talkOverCount = 3
        /// "Yeah." / "Mhmm." / "That's good." over their line is listening, not talking over.
        static let talkOverWords = 4
        /// They kept talking this long after you started; less is a normal turn change.
        static let talkOverOverlap: TimeInterval = 1.5
        static let shortReply: TimeInterval = 1.5
        static let shortFactor = 3.0
        static let speedFactor = 1.4
        static let speedRearm = 1.2
        static let speedWarmUp: TimeInterval = 300
        static let repeatWindow: TimeInterval = 600
        /// Content words each line needs, and the share of the longer line's
        /// that must match: "So we know from" is one word ("know") and matched every "you know".
        static let repeatTokens = 3
        static let repeatOverlap = 0.5
        static let questionAge: TimeInterval = 180
    }

    let gauges: [SentimentGauge]
    /// "Did they make the same point again?" Lexical for now: mean-pooled
    /// sentence embeddings have too high a baseline for a fixed threshold.
    /// Stricter than `isNearDuplicate`, which divides by the smaller set: a
    /// short line's one or two words are in most long ones.
    var samePoint: (String, String) -> Bool = { a, b in
        let ta = CallAnalysisEngine.significantTokens(a), tb = CallAnalysisEngine.significantTokens(b)
        return min(ta.count, tb.count) >= Tuning.repeatTokens
            && Double(ta.intersection(tb).count) / Double(max(ta.count, tb.count)) >= Tuning.repeatOverlap
    }

    /// Finished lines, sorted by start.
    private(set) var lines: [Line] = []
    private(set) var all: [Nudge] = []
    private var lastPass: Pass?
    /// Pass-driven nudges wait here for the next tick's rate limiter.
    private var pending: [Nudge] = []
    private var lastShownAt: TimeInterval?
    private var lastShownByKind: [Nudge.Kind: TimeInterval] = [:]
    // Per-rule memory, so one event is one nudge.
    private var quietAfter: TimeInterval?
    private var monologueFrom: TimeInterval?
    private var talkOverAfter: TimeInterval = -.infinity
    private var repliesUsed = 0
    private var speedArmed = true
    private var repeatChecked: TimeInterval?
    private var repeatUsed: Set<TimeInterval> = []
    private var questionsNudged: Set<String> = []
    private var wrapUpDone = false

    init(gauges: [SentimentGauge] = []) {
        self.gauges = gauges
    }

    mutating func add(_ line: Line) {
        let index = (lines.lastIndex { $0.start <= line.start } ?? -1) + 1
        lines.insert(line, at: index)
    }

    mutating func add(_ pass: Pass) {
        defer { lastPass = pass }
        if let previous = lastPass, let shift = moodShift(from: previous, to: pass) { pending.append(shift) }
        if pass.wrappingUp, !wrapUpDone, let wrap = wrapUp(pass) { pending.append(wrap) }
    }

    /// Everything due at `now` goes into `all`; the most useful one the rate
    /// limits allow is returned to show. `lastHeard`: call time each track
    /// last carried speech-level sound.
    mutating func tick(now: TimeInterval, lastHeard: [AudioSource: TimeInterval]) -> Nudge? {
        guard now >= Tuning.warmUp else {
            pending.removeAll()
            return nil
        }
        var due = pending
        pending.removeAll()
        if let n = unansweredQuestion(now: now) { due.append(n) }
        if let n = goneQuiet(now: now, lastHeard: lastHeard) { due.append(n) }
        if let n = talkingOver(now: now) { due.append(n) }
        if let n = repeatedPoint() { due.append(n) }
        if let n = longMonologue(now: now) { due.append(n) }
        if let n = shortAnswers(now: now) { due.append(n) }
        if let n = speedingUp(now: now) { due.append(n) }
        guard !due.isEmpty else { return nil }

        var shown: Nudge?
        for var nudge in due.sorted(by: { $0.kind.rank < $1.kind.rank }) {
            nudge.shown = shown == nil && canShow(nudge.kind, now: now)
            if nudge.shown {
                shown = nudge
                lastShownAt = now
                lastShownByKind[nudge.kind] = now
            }
            all.append(nudge)
        }
        return shown
    }

    private func canShow(_ kind: Nudge.Kind, now: TimeInterval) -> Bool {
        if let last = lastShownByKind[kind], now - last < Tuning.sameKindGap { return false }
        // The wrap-up checklist is the last chance: it skips the 2-minute gap.
        if kind == .wrapUp { return true }
        if let last = lastShownAt, now - last < Tuning.minGap { return false }
        return true
    }

    // MARK: - Timing rules

    /// Their lines that answer one of yours (the turn changed you → them).
    private var replies: [Line] {
        zip(lines, lines.dropFirst()).compactMap { a, b in a.source == .me && b.source == .them ? b : nil }
    }

    /// How long they usually take to answer: their own pace, not a fixed number.
    private var typicalReplyGap: TimeInterval {
        let gaps = zip(lines, lines.dropFirst()).compactMap { a, b -> Double? in
            guard a.source == .me, b.source == .them else { return nil }
            let gap = b.start - a.end
            return (0...20).contains(gap) ? gap : nil
        }
        return gaps.count >= 3 ? (Self.median(gaps) ?? Tuning.typicalReplyGap) : Tuning.typicalReplyGap
    }

    private mutating func goneQuiet(now: TimeInterval, lastHeard: [AudioSource: TimeInterval]) -> Nudge? {
        guard let last = lines.max(by: { $0.end < $1.end }), last.source == .me, quietAfter != last.end,
              lines.contains(where: { $0.source == .them }) else { return nil }
        let wait = max(Tuning.quietFloor, Tuning.quietFactor * typicalReplyGap)
        guard now - last.end >= wait,
              (lastHeard[.them] ?? 0) <= last.end + 0.5,
              (lastHeard[.me] ?? 0) <= last.end + 1.5 else { return nil }
        quietAfter = last.end
        return Nudge(kind: .goneQuiet, time: last.start,
                     text: "They've gone quiet since you said \u{201C}\(Self.short(last.text))\u{201D}",
                     quote: last.text)
    }

    private mutating func longMonologue(now: TimeInterval) -> Nudge? {
        guard let lastThem = lines.last(where: { $0.source == .them }) else { return nil }
        let run = lines.filter { $0.source == .me && $0.start >= lastThem.end }
        guard let first = run.first, let last = run.last, monologueFrom != first.start,
              last.end - first.start >= Tuning.monologue, now - last.end <= 5 else { return nil }
        monologueFrom = first.start
        let minutes = Int((last.end - first.start) / 60)
        let span = minutes >= 2 ? "\(minutes) minutes" : "over a minute"
        return Nudge(kind: .longMonologue, time: first.start, text: "You've been talking for \(span). Check in?")
    }

    private mutating func talkingOver(now: TimeInterval) -> Nudge? {
        let theirs = lines.filter { $0.source == .them }
        let events = lines.filter { me in
            me.source == .me && me.start > talkOverAfter && me.start > now - Tuning.talkOverWindow
                && me.duration >= 1 && me.words >= Tuning.talkOverWords
                && theirs.contains { t in
                    t.start < me.start && me.start < t.end - Tuning.talkOverOverlap
                        // The mic picking up their voice repeats their words: not you.
                        && !CallAnalysisEngine.isNearDuplicate(me.text, t.text)
                }
        }
        guard events.count >= Tuning.talkOverCount, let latest = events.last else { return nil }
        talkOverAfter = latest.start
        return Nudge(kind: .talkingOver, time: latest.start,
                     text: "You've talked over them \(events.count) times. Let them finish")
    }

    private mutating func shortAnswers(now: TimeInterval) -> Nudge? {
        let replies = self.replies
        guard replies.count >= 8, replies.count - 4 >= repliesUsed else { return nil }
        let recent = replies.suffix(4), earlier = replies.dropLast(4)
        let earlierMean = earlier.map(\.duration).reduce(0, +) / Double(earlier.count)
        // Seconds, not words: Turkish says in one long word what English says in four.
        guard recent.allSatisfy({ $0.duration < Tuning.shortReply }),
              earlierMean >= Tuning.shortFactor * Tuning.shortReply,
              let first = recent.first, let last = recent.last, now - last.end <= 60 else { return nil }
        repliesUsed = replies.count
        return Nudge(kind: .shortAnswers, time: first.start, text: "Their answers are getting short. Ask an open question")
    }

    private mutating func speedingUp(now: TimeInterval) -> Nudge? {
        let mine = lines.filter { $0.source == .me && $0.duration >= 2 }
        guard mine.map(\.duration).reduce(0, +) >= Tuning.speedWarmUp else { return nil }
        let recent = mine.filter { $0.end > now - 60 }
        let before = mine.filter { $0.end <= now - 60 }
        let seconds = recent.map(\.duration).reduce(0, +)
        guard seconds >= 15, before.count >= 10,
              let baseline = Self.median(before.map { Double($0.words) / $0.duration }), baseline > 0 else { return nil }
        let rate = Double(recent.map(\.words).reduce(0, +)) / seconds
        if rate <= Tuning.speedRearm * baseline { speedArmed = true }
        guard speedArmed, rate >= Tuning.speedFactor * baseline else { return nil }
        speedArmed = false
        return Nudge(kind: .speedingUp, time: max(0, now - 60), text: "You're talking faster than usual. Slow down")
    }

    private mutating func repeatedPoint() -> Nudge? {
        guard let latest = lines.last(where: { $0.source == .them }), latest.start != repeatChecked else { return nil }
        repeatChecked = latest.start
        guard latest.duration >= 1.5, latest.words >= 4, !repeatUsed.contains(latest.start) else { return nil }
        let earlier = lines.filter {
            $0.source == .them && $0.start < latest.start && $0.start > latest.start - Tuning.repeatWindow
                && $0.duration >= 1.5 && !repeatUsed.contains($0.start) && samePoint(latest.text, $0.text)
        }
        guard earlier.count >= 2 else { return nil }
        repeatUsed.formUnion(earlier.map(\.start) + [latest.start])
        return Nudge(kind: .repeatedPoint, time: latest.start,
                     text: "They've said \u{201C}\(Self.short(latest.text))\u{201D} \(earlier.count + 1) times. Acknowledge it",
                     quote: latest.text)
    }

    // MARK: - Copilot rules

    private mutating func unansweredQuestion(now: TimeInterval) -> Nudge? {
        guard let q = lastPass?.openQuestions.first(where: {
            now - $0.since >= Tuning.questionAge && !questionsNudged.contains($0.title.lowercased())
        }) else { return nil }
        questionsNudged.insert(q.title.lowercased())
        let minutes = max(1, Int((now - q.since) / 60))
        return Nudge(kind: .unansweredQuestion, time: q.since,
                     text: "Asked \(minutes) min ago and still open: \(Self.short(q.title))", quote: q.title)
    }

    private func moodShift(from old: Pass, to new: Pass) -> Nudge? {
        let moves = gauges.filter { $0.key != "my_dominance" }.compactMap { g -> (gauge: SentimentGauge, delta: Int)? in
            guard let a = old.values[g.key], let b = new.values[g.key],
                  abs(b - a) >= ToneTimeline.turnThreshold else { return nil }
            return (g, b - a)
        }
        guard let move = moves.max(by: { abs($0.delta) < abs($1.delta) }) else { return nil }
        let spans = lines.map { ToneTimeline.Span(isMe: $0.source == .me, start: $0.start, end: $0.end, text: $0.text) }
        let line = ToneTimeline.cause(spans, after: old.time, upTo: new.time)
        return Nudge(kind: .moodShift, time: line?.start ?? new.time,
                     text: ToneTimeline.shiftText(move.gauge, rising: move.delta > 0, quote: line?.text),
                     quote: line?.text)
    }

    private mutating func wrapUp(_ pass: Pass) -> Nudge? {
        var items: [String] = pass.nextStepAgreed ? [] : ["agree a next step"]
        for item in pass.openQuestions.map(\.title) + pass.openItems where !items.contains(item) {
            items.append(item)
        }
        guard !items.isEmpty else { return nil }
        wrapUpDone = true
        let list = items.prefix(3).map { Self.short($0, max: 40) }.joined(separator: "; ")
        return Nudge(kind: .wrapUp, time: pass.time, text: "Before you hang up: \(list)")
    }

    // MARK: - Replay

    /// A saved call through the rules second by second, as live: lines arrive
    /// 1 s after they end (decode time), a track counts as heard while one of
    /// its lines is in progress. No `timeline`: timing rules only. Runs every
    /// rule once per call second, so cache the result.
    static func replay(lines: [Line], timeline: MoodTimeline?, duration: TimeInterval) -> [Nudge] {
        var detector = NudgeDetector(gauges: timeline?.gauges ?? [])
        var waiting = lines.sorted { $0.end < $1.end }
        var passes = timeline?.snapshots ?? []
        var heard: [AudioSource: TimeInterval] = [:]
        let end = max(duration, lines.map(\.end).max() ?? 0) + 30
        var t: TimeInterval = 0
        while t <= end {
            while let line = waiting.first, line.end + 1 <= t {
                detector.add(line)
                waiting.removeFirst()
            }
            while let pass = passes.first, pass.time <= t {
                detector.add(Pass(time: pass.time, values: pass.values))
                passes.removeFirst()
            }
            for line in lines where line.start <= t && line.end >= t - 1 {
                heard[line.source] = max(heard[line.source] ?? 0, min(t, line.end))
            }
            _ = detector.tick(now: t, lastHeard: heard)
            t += 1
        }
        return detector.all
    }

    // MARK: - Helpers

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// A quote short enough for the pill: whole words, at most `max` characters.
    static func short(_ text: String, max: Int = 60) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > max else { return clean }
        var out = ""
        for word in clean.split(separator: " ") {
            if out.count + word.count + (out.isEmpty ? 0 : 1) > max { break }
            out += out.isEmpty ? String(word) : " " + word
        }
        return (out.isEmpty ? String(clean.prefix(max)) : out) + "\u{2026}"
    }
}
