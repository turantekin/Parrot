# Live Nudges and Tone Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nine live nudges during a call (floating pill + Copilot panel banner) and a "How the call went" timeline card in the report, all from timing and the Copilot's existing gauges.

**Architecture:** A pure `NudgeDetector` struct holds every rule and the rate limiter; `LiveNudgeSession` (MainActor, observable) owns one call's detector and mood snapshots and is fed by `RecordingManager` (finished lines, Copilot passes, a 1 s tick on the audio clock). A pure `ToneTimeline` enum does the report maths; `ToneTimelineCard` draws it. Results are stored as JSON on `Meeting` like `bookmarksData`.

**Tech Stack:** Swift 5.10, SwiftUI + AppKit (`NSPanel`), SwiftData, the `--profile-test` harness (`make test`).

## Global Constraints

- Base branch: `feat/profiles2-reports` (PR #84). Work on `feat/live-nudges-tone-timeline`.
- Spec: `docs/superpowers/specs/2026-09-29-live-nudges-tone-timeline-design.md`.
- Build and test with the Makefile only: `make test` (builds release, runs `--profile-test`, must end `ALL PASS`). Run `swift build` before any `.build/debug` harness.
- Style through `Theme.swift`; no hex or magic colours in views. UI text short, plain English.
- New SwiftData fields must be optional/defaulted (lightweight migration).
- No emotion from the voice. Nudge text says what happened, not what someone feels.
- Report system prompts are golden-tested (`testReportTemplateGolden`); do not change them.
- Analysis prompt must never contain the word "objection" (`testPromptAndSchema`).
- New files are picked up by SwiftPM automatically; run `make xcode` at the end so the pbxproj lists them.

## Deviations from the spec (decided while planning)

1. **Repeated point** uses the lexical near-duplicate test already in the app (`CallAnalysisEngine.isNearDuplicate`), not sentence embeddings. Apple's contextual embeddings are mean-pooled and have a high baseline cosine (the KB work found no usable floor), so an absolute "same point" threshold would misfire. The rule takes a `samePoint` closure, so embeddings can replace it after `--nudge-replay` tuning.
2. **Turning point / mood-shift quote** = the line with the most words that ended between the two Copilot passes, not "the last line" (the last line is often "okay").
3. **`moodTimelineData`** stores `MoodTimeline { gauges, snapshots }` (not a bare array) so the report can label the line after the profile changes.
4. **Clock:** the detector runs on the audio sample clock (`TranscriptionEngine.speechClock()`), the same clock as segment timestamps, so a late system-audio tap can't skew "gone quiet".

---

### Task 1: Nudge models and Meeting fields

**Files:**
- Create: `Parrot/Models/Nudge.swift`
- Modify: `Parrot/Models/Meeting.swift` (fields after `bookmarksData`, accessors after `bookmarks`)
- Modify: `Parrot/ProfileTest.swift` (`private static func check` → `static func check`; register tests in `run()`)
- Create: `Parrot/ProfileTest+Nudges.swift`

**Interfaces:**
- Produces: `Nudge { id, kind: Nudge.Kind, time, text, quote?, shown }`, `Nudge.Kind` (9 cases, `rank`, `title`, `symbol`), `MoodSnapshot { time, values: [String: Int] }`, `MoodTimeline { gauges: [SentimentGauge], snapshots: [MoodSnapshot] }`, `Meeting.nudges: [Nudge]`, `Meeting.moodTimeline: MoodTimeline?`.

- [ ] **Step 1: Write the failing test** in `Parrot/ProfileTest+Nudges.swift`:

```swift
import Foundation

/// Live nudges and the tone timeline (spec 2026-09-29).
extension ProfileTest {
    static func testNudgeModels() {
        let n = Nudge(kind: .goneQuiet, time: 125, text: "They've gone quiet", quote: "the price")
        let back = try? JSONDecoder().decode(Nudge.self, from: JSONEncoder().encode(n))
        check("nudge: JSON round trip", back == n)
        check("nudge: wrap-up outranks everything", Nudge.Kind.allCases.min { $0.rank < $1.rank } == .wrapUp)
        let m = Meeting(title: "t")
        check("nudge: meeting starts with none", m.nudges.isEmpty && m.moodTimeline == nil)
        m.nudges = [Nudge(kind: .speedingUp, time: 300, text: "b"), n]
        check("nudge: stored time-sorted", m.nudges.map(\.time) == [125, 300])
        m.nudges = []
        check("nudge: empty clears the field", m.nudgesData == nil)
        let g = SentimentGauge(id: UUID(), key: "f", label: "Frustration", lowLabel: "Calm", highLabel: "Upset", colorHex: "E8943A")
        m.moodTimeline = MoodTimeline(gauges: [g], snapshots: [MoodSnapshot(time: 10, values: ["f": 40])])
        check("nudge: mood timeline round trip", m.moodTimeline?.snapshots.first?.values["f"] == 40)
        m.moodTimeline = MoodTimeline(gauges: [g], snapshots: [])
        check("nudge: empty timeline clears the field", m.moodTimelineData == nil)
    }
}
```

Register in `ProfileTest.run()` before the `print(failures == 0 ...)` line: `testNudgeModels()`. Change `private static func check` to `static func check` (the extension file needs it).

- [ ] **Step 2: Run** `swift build 2>&1 | tail -5`. Expected: FAIL, `cannot find 'Nudge' in scope`.

- [ ] **Step 3: Implement** `Parrot/Models/Nudge.swift`:

```swift
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
```

In `Meeting.swift`, after `var bookmarksData: Data? = nil`:

```swift
    /// Live nudges from this call (JSON [Nudge]); see `nudges`. Defaulted → old rows migrate.
    var nudgesData: Data? = nil
    /// The Copilot's gauges after each pass (JSON MoodTimeline); see `moodTimeline`.
    var moodTimelineData: Data? = nil
```

After the `bookmarks` accessor:

```swift
    /// Live nudges, time-sorted (see `nudgesData`).
    var nudges: [Nudge] {
        get {
            guard let data = nudgesData else { return [] }
            return ((try? JSONDecoder().decode([Nudge].self, from: data)) ?? []).sorted { $0.time < $1.time }
        }
        set {
            nudgesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue.sorted { $0.time < $1.time })
        }
    }

    /// Gauge history for the report's tone timeline (see `moodTimelineData`).
    var moodTimeline: MoodTimeline? {
        get { moodTimelineData.flatMap { try? JSONDecoder().decode(MoodTimeline.self, from: $0) } }
        set {
            guard let newValue, !newValue.snapshots.isEmpty else { moodTimelineData = nil; return }
            moodTimelineData = try? JSONEncoder().encode(newValue)
        }
    }
```

- [ ] **Step 4: Run** `make test 2>&1 | grep -E 'nudge:|ALL PASS|FAIL'`. Expected: all `PASS nudge:` lines, `ALL PASS`.
- [ ] **Step 5: Commit** `git add -A Parrot && git commit -m "Nudges: the saved nudge and mood timeline on each meeting"`

---

### Task 2: NudgeDetector — timing rules and the rate limiter

**Files:**
- Create: `Parrot/Services/NudgeDetector.swift`
- Test: `Parrot/ProfileTest+Nudges.swift` (`testNudgeRules`)

**Interfaces:**
- Consumes: `Nudge`, `SentimentGauge`, `AudioSource` (`.me`, `.them`), `CallAnalysisEngine.isNearDuplicate(_:_:threshold:)`.
- Produces:
  - `struct NudgeDetector { init(gauges: [SentimentGauge] = []); mutating func add(_ line: Line); mutating func add(_ pass: Pass); mutating func tick(now: TimeInterval, lastHeard: [AudioSource: TimeInterval]) -> Nudge?; private(set) var all: [Nudge]; var samePoint: (String, String) -> Bool }`
  - `NudgeDetector.Line { source, start, end, text }`, `NudgeDetector.OpenQuestion { title, since }`, `NudgeDetector.Pass { time, values, openQuestions, openItems, wrappingUp, nextStepAgreed }`
  - `static func short(_ text: String, max: Int = 60) -> String`, `static func median(_ values: [Double]) -> Double?`

- [ ] **Step 1: Write the failing tests** (append to the extension; register `testNudgeRules()` in `run()`):

```swift
    private static func said(_ s: AudioSource, _ a: TimeInterval, _ b: TimeInterval,
                             _ text: String = "a few words said here") -> NudgeDetector.Line {
        NudgeDetector.Line(source: s, start: a, end: b, text: text)
    }

    private static func words(_ n: Int) -> String { Array(repeating: "word", count: n).joined(separator: " ") }

    /// Ten normal turns (you 5 s, a pause of `gap`, them 5 s), each on its own
    /// topic so "repeated point" stays out of tests about other rules.
    private static func backAndForth(every: TimeInterval = 12, gap: TimeInterval = 1) -> [NudgeDetector.Line] {
        let topics = ["apples", "budget", "calendar", "delivery", "engineers", "finance", "growth", "hiring", "invoices", "journey"]
        return topics.enumerated().flatMap { i, topic in
            let t = Double(i) * every
            return [said(.me, t, t + 5, "what about \(topic) plans"), said(.them, t + 5 + gap, t + 10 + gap, "our \(topic) story goes like this")]
        }
    }

    static func testNudgeRules() {
        // Gone quiet: they usually answer in ~1 s, so 6 s of silence is the floor.
        var d = NudgeDetector()
        backAndForth().forEach { d.add($0) }
        d.add(said(.me, 125, 130, "the price goes up in January"))
        check("quiet: not before the wait", d.tick(now: 135, lastHeard: [.me: 130, .them: 119]) == nil)
        let quiet = d.tick(now: 136.5, lastHeard: [.me: 130, .them: 119])
        check("quiet: fires after 6 s of silence", quiet?.kind == .goneQuiet)
        check("quiet: quotes your line", quiet?.text.contains("the price goes up in January") == true)
        check("quiet: marked at your line", quiet?.time == 125)
        check("quiet: once per line", d.tick(now: 150, lastHeard: [.me: 130, .them: 119]) == nil)

        var talking = NudgeDetector()
        backAndForth().forEach { talking.add($0) }
        talking.add(said(.me, 125, 130))
        check("quiet: not while they're talking", talking.tick(now: 140, lastHeard: [.me: 130, .them: 139]) == nil)

        var slow = NudgeDetector()
        backAndForth(every: 15, gap: 4).forEach { slow.add($0) }
        slow.add(said(.me, 150, 155))
        check("quiet: a slow speaker gets 3x their gap", slow.tick(now: 163, lastHeard: [.me: 155, .them: 144]) == nil)
        check("quiet: …and then it fires", slow.tick(now: 167.5, lastHeard: [.me: 155, .them: 144])?.kind == .goneQuiet)

        // Long monologue: 90 s of you after their last line, still talking.
        var mono = NudgeDetector()
        mono.add(said(.them, 100, 110, "tell me about it"))
        mono.add(said(.me, 112, 150, "first part")); mono.add(said(.me, 151, 190, "second part")); mono.add(said(.me, 191, 205, "third part"))
        let long = mono.tick(now: 206, lastHeard: [.me: 205])
        check("monologue: fires past 90 s", long?.kind == .longMonologue && long?.text.contains("over a minute") == true)
        check("monologue: once per run", mono.tick(now: 207, lastHeard: [.me: 206]) == nil)

        // Talking over: 3 starts inside their lines within 5 min; echo doesn't count.
        let theirLines = ["we need the integration by March", "the budget is approved already", "our team starts in April"]
        var over = NudgeDetector()
        for (i, a) in [130.0, 150, 170].enumerated() {
            over.add(said(.them, a, a + 10, theirLines[i]))
            over.add(said(.me, a + 5, a + 7, "sorry, quick question on pricing"))
        }
        check("talk over: fires on the third", over.tick(now: 180, lastHeard: [:])?.kind == .talkingOver)
        var echo = NudgeDetector()
        for (i, a) in [130.0, 150, 170].enumerated() {
            echo.add(said(.them, a, a + 10, theirLines[i]))
            echo.add(said(.me, a + 5, a + 7, theirLines[i]))
        }
        check("talk over: mic echo of their words isn't you", echo.tick(now: 180, lastHeard: [:]) == nil)

        // Short answers: 4 short replies after long ones (backchannels don't count).
        var short = NudgeDetector()
        var s: TimeInterval = 0
        for i in 0..<8 {
            short.add(said(.me, s, s + 3, "question \(i) for you"))
            let length: TimeInterval = i < 4 ? 6 : 1
            short.add(said(.them, s + 4, s + 4 + length, "answer \(i)"))
            s += 20
        }
        check("short answers: fires", short.tick(now: s, lastHeard: [:])?.kind == .shortAnswers)
        check("short answers: needs 4 new replies to fire again", short.tick(now: s + 1, lastHeard: [:]) == nil)

        // Speeding up: 1.4x your own median words/second over the last minute.
        var fast = NudgeDetector()
        for i in 0..<30 { fast.add(said(.me, Double(i) * 12, Double(i) * 12 + 10, words(25))) }
        fast.add(said(.me, 362, 372, words(40))); fast.add(said(.me, 374, 384, words(40)))
        check("speeding up: fires at 1.6x", fast.tick(now: 385, lastHeard: [:])?.kind == .speedingUp)
        check("speeding up: not again while still fast", fast.tick(now: 386, lastHeard: [:]) == nil)

        // Repeated point: the same complaint 3 times in 10 minutes.
        var again = NudgeDetector()
        for a in [200.0, 300, 400] { again.add(said(.them, a, a + 3, "the export still does not work for us")) }
        let repeated = again.tick(now: 404, lastHeard: [:])
        check("repeated: fires on the third", repeated?.kind == .repeatedPoint && repeated?.text.contains("3 times") == true)
        var okays = NudgeDetector()
        for a in [200.0, 300, 400] { okays.add(said(.them, a, a + 2, "okay yes")) }
        check("repeated: short fillers don't count", okays.tick(now: 404, lastHeard: [:]) == nil)

        // Warm-up: nothing in the first 2 minutes.
        var early = NudgeDetector()
        early.add(said(.them, 10, 12)); early.add(said(.me, 20, 25))
        check("warm-up: silent before 2 min", early.tick(now: 60, lastHeard: [.me: 25, .them: 12]) == nil && early.all.isEmpty)

        check("short: whole words + ellipsis", NudgeDetector.short("one two three four", max: 10) == "one two…")
        check("median: even count", NudgeDetector.median([1, 2, 3, 4]) == 2.5)
    }
```

- [ ] **Step 2: Run** `swift build 2>&1 | tail -3`. Expected: FAIL, `cannot find 'NudgeDetector'`.

- [ ] **Step 3: Implement** `Parrot/Services/NudgeDetector.swift`:

```swift
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
        static let shortReply: TimeInterval = 1.5
        static let shortFactor = 3.0
        static let speedFactor = 1.4
        static let speedRearm = 1.2
        static let speedWarmUp: TimeInterval = 300
        static let repeatWindow: TimeInterval = 600
        static let questionAge: TimeInterval = 180
    }

    let gauges: [SentimentGauge]
    /// "Did they make the same point again?" Lexical for now: mean-pooled
    /// sentence embeddings have too high a baseline for a fixed threshold.
    var samePoint: (String, String) -> Bool = { CallAnalysisEngine.isNearDuplicate($0, $1) }

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

    /// How long they usually take to answer; their own pace, not a fixed number.
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
                && me.duration >= 1
                && theirs.contains { t in
                    t.start < me.start && me.start < t.end - 0.3
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

    // MARK: - Copilot rules (Task 4)

    private mutating func unansweredQuestion(now: TimeInterval) -> Nudge? { nil }
    private func moodShift(from old: Pass, to new: Pass) -> Nudge? { nil }
    private mutating func wrapUp(_ pass: Pass) -> Nudge? { nil }

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
```

- [ ] **Step 4: Run** `make test 2>&1 | grep -E 'quiet:|monologue:|talk over:|short answers:|speeding up:|repeated:|warm-up:|short:|median:|ALL PASS|FAIL'`. Expected: every listed check PASS, `ALL PASS`.
- [ ] **Step 5: Commit** `git commit -am "Nudges: the timing rules and the rate limiter" && git add Parrot/Services/NudgeDetector.swift && git commit --amend --no-edit`

---

### Task 3: ToneTimeline maths and one talk percentage (seconds)

**Files:**
- Create: `Parrot/Services/ToneTimeline.swift`
- Modify: `Parrot/Models/Meeting.swift` (`talkPercentMe` body)
- Modify: `Parrot/Services/CallAnalysisEngine.swift` (`meCharacters`/`themCharacters` → seconds; `ingest` gains `duration:`; `seedForSnapshot` params)
- Modify: `Parrot/Services/AnalysisProvider.swift` (`coachingUserContent`: "of the words" → "of the speaking time")
- Modify: `Parrot/Services/RecordingManager.swift` (`ingest(... duration:)`), `Parrot/SnapshotTool.swift` and `Parrot/ProfileTest.swift` (`seedForSnapshot` call sites)
- Test: `testToneTimeline`, `testTalkSeconds`

**Interfaces:**
- Produces: `ToneTimeline.turnThreshold = 25`, `ToneTimeline.Span { isMe, start, end, text }`, `spans(_ segments: [TranscriptSegment]) -> [Span]`, `talkByMinute(_:duration:) -> [Minute]`, `talkPercentMe(_ spans: [Span]) -> Int?`, `mainGauge(_:) -> SentimentGauge?`, `level(_:_:) -> String`, `cause(_:after:upTo:) -> Span?`, `turningPoints(_:gauge:spans:) -> [TurningPoint]`, `moments(nudges:turns:marks:) -> [Moment]`, `model(duration:spans:nudges:timeline:marks:) -> Model?`.
- `CallAnalysisEngine.ingest(text:at:source:duration: TimeInterval? = nil)`; `seedForSnapshot(... meSeconds: TimeInterval, themSeconds: TimeInterval)`.

- [ ] **Step 1: Failing tests** (register `testToneTimeline()` and `testTalkSeconds()`):

```swift
    static func testToneTimeline() {
        typealias TT = ToneTimeline
        let spans = [
            TT.Span(isMe: true, start: 50, end: 70, text: "we can't do that date"),
            TT.Span(isMe: false, start: 70, end: 100, text: "okay"),
            TT.Span(isMe: false, start: 170, end: 200, text: "past the end"),
        ]
        let minutes = TT.talkByMinute(spans, duration: 150)
        check("timeline: one bar per minute", minutes.count == 3)
        check("timeline: a line split across minutes", minutes[0].me == 10 && minutes[1].me == 10 && minutes[1].them == 30)
        check("timeline: past the end lands in the last minute", minutes[2].them == 30)
        let calm = SentimentGauge(id: UUID(), key: "f", label: "Frustration", lowLabel: "Calm", highLabel: "Upset", colorHex: "E8943A")
        let talk = SentimentGauge(id: UUID(), key: "my_dominance", label: "You're talking", lowLabel: "Balanced", highLabel: "Dominating", colorHex: "5F6470")
        check("timeline: main gauge skips talk balance", TT.mainGauge([talk, calm])?.key == "f")
        check("timeline: level words", TT.level(10, calm) == "Calm" && TT.level(90, calm) == "Upset" && TT.level(50, calm) == "In between")
        let snaps = [MoodSnapshot(time: 40, values: ["f": 20]), MoodSnapshot(time: 60, values: ["f": 30]),
                     MoodSnapshot(time: 80, values: ["f": 70]), MoodSnapshot(time: 95, values: ["f": 30])]
        let turns = TT.turningPoints(snaps, gauge: calm, spans: spans)
        check("timeline: two turning points", turns.count == 2)
        check("timeline: quotes the wordiest line between passes", turns.first?.text == "Frustration moved toward Upset after \u{201C}we can't do that date\u{201D}")
        check("timeline: no line between → pass time, no quote", turns.last?.time == 95 && turns.last?.quote == nil)
        let shift = Nudge(kind: .moodShift, time: turns[0].time, text: "shift")
        let quiet = Nudge(kind: .goneQuiet, time: 10, text: "quiet")
        let moments = TT.moments(nudges: [shift, quiet], turns: turns, marks: [Bookmark(time: 90, label: "price")])
        check("timeline: moments numbered by time", moments.map(\.number) == [1, 2, 3, 4] && moments.map(\.time) == [10, 50, 90, 95])
        check("timeline: a mood-shift nudge hides its duplicate turn", moments.filter { $0.kind == .turn }.count == 1)
        check("timeline: no card without both sides", TT.model(duration: 60, spans: [spans[1]], nudges: [], timeline: nil, marks: []) == nil)
        let model = TT.model(duration: 150, spans: spans, nudges: [], timeline: MoodTimeline(gauges: [calm], snapshots: snaps), marks: [])
        check("timeline: model carries the mood line", model?.mood.count == 4 && model?.gauge?.key == "f" && model?.endLevel == "Calm")
    }

    @MainActor
    static func testTalkSeconds() {
        let spans = [ToneTimeline.Span(isMe: true, start: 0, end: 60, text: "evet"),
                     ToneTimeline.Span(isMe: false, start: 60, end: 120, text: words(30))]
        check("talk: seconds, not words", ToneTimeline.talkPercentMe(spans) == 50)
        check("talk: nobody spoke → nil", ToneTimeline.talkPercentMe([]) == nil)
        let engine = CallAnalysisEngine()
        engine.seedForSnapshot(profile: nil, insights: [], sentiment: [:], read: nil, meSeconds: 30, themSeconds: 70)
        check("talk: live share in seconds", engine.userTalkPercent == 30)
        let content = ClaudeAnalysisProvider.coachingUserContent(transcript: "x", talkPercentMe: 40, instructions: "", counterpart: "Sam")
        check("talk: coaching prompt says speaking time", content.contains("40% of the speaking time"))
    }
```

(Check the exact `seedForSnapshot` and `coachingUserContent` signatures in the files first and match them; only the two talk params change.)

- [ ] **Step 2: Run** `swift build 2>&1 | tail -3`. Expected: FAIL, `cannot find 'ToneTimeline'`.

- [ ] **Step 3: Implement** `Parrot/Services/ToneTimeline.swift`:

```swift
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
                let index = min(count - 1, Int(t / 60))
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

    static func turningPoints(_ snapshots: [MoodSnapshot], gauge: SentimentGauge, spans: [Span]) -> [TurningPoint] {
        let points = snapshots.compactMap { s in s.values[gauge.key].map { MoodPoint(time: s.time, value: $0) } }
        return zip(points, points.dropFirst()).compactMap { a, b in
            guard abs(b.value - a.value) >= turnThreshold else { return nil }
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
        let mood = gauge.map { g in
            (timeline?.snapshots ?? []).compactMap { s in s.values[g.key].map { MoodPoint(time: s.time, value: $0) } }
        } ?? []
        let turns = gauge.map { turningPoints(timeline?.snapshots ?? [], gauge: $0, spans: spans) } ?? []
        return Model(duration: length, minutes: talkByMinute(spans, duration: length),
                     talkPercentMe: talkPercentMe(spans), gauge: mood.isEmpty ? nil : gauge, mood: mood,
                     endLevel: gauge.flatMap { g in mood.last.map { level($0.value, g) } },
                     moments: moments(nudges: nudges, turns: turns, marks: marks))
    }
}
```

`Meeting.talkPercentMe` body becomes:

```swift
    /// Me's share of the speaking time, nil when nobody spoke.
    var talkPercentMe: Int? { ToneTimeline.talkPercentMe(ToneTimeline.spans(segments)) }
```

In `CallAnalysisEngine`: rename `meCharacters`/`themCharacters` to `meSeconds`/`themSeconds: TimeInterval`; in `ingest` add a trailing `duration: TimeInterval? = nil` parameter and add `duration ?? Double(text.count) / 15` (about 15 characters a second when no timing is known) to the right counter instead of `text.count`; `userTalkPercent` guards `total >= 30` (was 400 characters ≈ 27 s); reset both to 0 in `start`; `seedForSnapshot` takes `meSeconds:themSeconds:`. Update the three `SnapshotTool.swift` call sites (values ÷ 15: 620→41, 780→52, 1300→87, 900→60, 0→0) and `ProfileTest.swift:1639`. In `RecordingManager` `onSegment`, pass `duration: result.endTime - result.startTime`. In `AnalysisProvider.coachingUserContent`, change `"of the words, "` to `"of the speaking time, "`.

- [ ] **Step 4: Run** `make test 2>&1 | grep -E 'timeline:|talk:|golden|ALL PASS|FAIL'`. Expected: all PASS including the golden checks, `ALL PASS`.
- [ ] **Step 5: Commit** `git add -A Parrot && git commit -m "Tone timeline maths; talk share counts seconds everywhere"`

---

### Task 4: NudgeDetector — Copilot rules

**Files:**
- Modify: `Parrot/Services/NudgeDetector.swift` (replace the three Task 4 stubs)
- Test: `testNudgeCopilotRules`, `testNudgeLimiter`

**Interfaces:**
- Consumes: `ToneTimeline.turnThreshold`, `ToneTimeline.cause`, `ToneTimeline.shiftText`, `ToneTimeline.Span`.

- [ ] **Step 1: Failing tests** (register both):

```swift
    private static let upset = SentimentGauge(id: UUID(), key: "f", label: "Frustration", lowLabel: "Calm", highLabel: "Upset", colorHex: "E8943A")

    static func testNudgeCopilotRules() {
        var d = NudgeDetector(gauges: [upset])
        d.add(NudgeDetector.Pass(time: 150, values: ["f": 20]))
        d.add(said(.me, 155, 160, "we can't do that date sorry"))
        d.add(said(.them, 161, 162, "ok"))
        d.add(NudgeDetector.Pass(time: 170, values: ["f": 60]))
        let shift = d.tick(now: 171, lastHeard: [.them: 170, .me: 170])
        check("mood: fires on a 25+ move", shift?.kind == .moodShift)
        check("mood: same words as the report", shift?.text == "Frustration moved toward Upset after \u{201C}we can't do that date sorry\u{201D}")

        var q = NudgeDetector()
        q.add(NudgeDetector.Pass(time: 130, values: [:], openQuestions: [.init(title: "Contract length?", since: 130)]))
        check("question: not before 3 minutes", q.tick(now: 200, lastHeard: [:]) == nil)
        let open = q.tick(now: 311, lastHeard: [:])
        check("question: fires when still open", open?.kind == .unansweredQuestion && open?.text.contains("Contract length?") == true)
        check("question: once per question", q.tick(now: 700, lastHeard: [:]) == nil)
        var answered = NudgeDetector()
        answered.add(NudgeDetector.Pass(time: 130, values: [:], openQuestions: [.init(title: "Q", since: 130)]))
        answered.add(NudgeDetector.Pass(time: 200, values: [:]))
        check("question: answered means no nudge", answered.tick(now: 400, lastHeard: [:]) == nil)

        var w = NudgeDetector()
        w.add(NudgeDetector.Pass(time: 600, values: [:], openItems: ["Price too high"], wrappingUp: true, nextStepAgreed: false))
        let wrap = w.tick(now: 601, lastHeard: [:])
        check("wrap-up: lists next step and open items", wrap?.text == "Before you hang up: agree a next step; Price too high")
        w.add(NudgeDetector.Pass(time: 620, values: [:], openItems: ["Price too high"], wrappingUp: true))
        check("wrap-up: once per call", w.tick(now: 621, lastHeard: [:]) == nil)
        var done = NudgeDetector()
        done.add(NudgeDetector.Pass(time: 600, values: [:], wrappingUp: true, nextStepAgreed: true))
        check("wrap-up: nothing open → no nudge", done.tick(now: 601, lastHeard: [:]) == nil)
    }

    static func testNudgeLimiter() {
        var d = NudgeDetector(gauges: [upset])
        d.add(NudgeDetector.Pass(time: 50, values: ["f": 10]))
        d.add(NudgeDetector.Pass(time: 60, values: ["f": 90]))
        check("limiter: warm-up drops early nudges", d.tick(now: 61, lastHeard: [:]) == nil && d.tick(now: 130, lastHeard: [:]) == nil && d.all.isEmpty)
        d.add(NudgeDetector.Pass(time: 140, values: ["f": 30]))
        check("limiter: first one shows", d.tick(now: 141, lastHeard: [:])?.kind == .moodShift)
        d.add(NudgeDetector.Pass(time: 190, values: ["f": 30], openQuestions: [.init(title: "Q1", since: 0)]))
        check("limiter: 2-minute gap holds the next", d.tick(now: 191, lastHeard: [:]) == nil)
        d.add(NudgeDetector.Pass(time: 270, values: ["f": 30], openQuestions: [.init(title: "Q2", since: 0)]))
        check("limiter: shows again after the gap", d.tick(now: 271, lastHeard: [:])?.quote == "Q2")
        d.add(NudgeDetector.Pass(time: 280, values: ["f": 30], wrappingUp: true))
        check("limiter: wrap-up skips the gap", d.tick(now: 281, lastHeard: [:])?.kind == .wrapUp)
        check("limiter: held ones are kept for the report", d.all.map(\.shown) == [true, false, true, true])
    }
```

- [ ] **Step 2: Run** `make test 2>&1 | grep -E 'mood:|question:|wrap-up:|limiter:'`. Expected: FAIL lines (stubs return nil).

- [ ] **Step 3: Implement** — replace the three stubs:

```swift
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
```

Note: the question test expects `open?.text.contains("Contract length?")`; `short()` keeps it whole (under 60 characters).

- [ ] **Step 4: Run** `make test 2>&1 | grep -E 'mood:|question:|wrap-up:|limiter:|ALL PASS|FAIL'`. Expected: all PASS, `ALL PASS`.
- [ ] **Step 5: Commit** `git commit -am "Nudges: mood shift, unanswered question and the wrap-up checklist"`

---

### Task 5: Copilot flags and the pass callback

**Files:**
- Modify: `Parrot/Services/AnalysisProvider.swift` (`systemPrompt` sentiment bullets, `schema` sentiment props + required)
- Modify: `Parrot/Services/CallAnalysisEngine.swift` (constants, `onPassCompleted`, static `nudgePass`, call it at the end of a successful pass)
- Test: `testCopilotFlags`

**Interfaces:**
- Produces: `CallAnalysisEngine.wrappingUpKey = "wrapping_up"`, `nextStepKey = "next_step_agreed"`, `questionKinds: Set<String> = ["question", "unanswered_question"]`, `var onPassCompleted: ((NudgeDetector.Pass) -> Void)?`, `nonisolated static func nudgePass(time:sentiment:insights:gauges:pinnedKinds:) -> NudgeDetector.Pass`.

- [ ] **Step 1: Failing test** (register):

```swift
    static func testCopilotFlags() {
        let schema = ClaudeAnalysisProvider.schema(kinds: [], gauges: [])
        let sentiment = (schema["properties"] as? [String: Any])?["sentiment"] as? [String: Any]
        let props = sentiment?["properties"] as? [String: Any]
        let required = sentiment?["required"] as? [String] ?? []
        check("flags: schema asks wrapping_up", (props?["wrapping_up"] as? [String: Any])?["type"] as? String == "boolean")
        check("flags: schema asks next_step_agreed", (props?["next_step_agreed"] as? [String: Any])?["type"] as? String == "boolean")
        check("flags: both required", required.contains("wrapping_up") && required.contains("next_step_agreed"))
        let prompt = ClaudeAnalysisProvider.systemPrompt(persona: "P", kinds: [], gauges: [])
        check("flags: prompt explains them", prompt.contains("\"wrapping_up\"") && prompt.contains("\"next_step_agreed\""))
        let parsed = try? ClaudeAnalysisProvider.parseAnalysisPayload(
            #"{"insights":[],"sentiment":{"coach":"c","score":50,"read":"r","wrapping_up":true,"next_step_agreed":false,"f":40},"resolved":[]}"#)
        check("flags: parsed as 1/0", parsed?.sentiment["wrapping_up"] == 1 && parsed?.sentiment["next_step_agreed"] == 0 && parsed?.sentiment["f"] == 40)
        let insights = [
            Insight(kindKey: "question", title: "Contract length?", detail: "", callTime: 90, source: nil),
            Insight(kindKey: "blocker", title: "Price too high", detail: "", callTime: 80, source: nil),
            Insight(kindKey: "question", title: "Done one", detail: "", callTime: 70, source: nil, isHandled: true),
        ]
        let pass = CallAnalysisEngine.nudgePass(time: 100, sentiment: ["f": 40, "score": 60, "wrapping_up": 1], insights: insights,
                                                gauges: [upset], pinnedKinds: ["blocker"])
        check("flags: pass keeps profile gauges only", pass.values == ["f": 40])
        check("flags: open questions, not handled ones", pass.openQuestions == [.init(title: "Contract length?", since: 90)])
        check("flags: pinned open items", pass.openItems == ["Price too high"])
        check("flags: wrap-up read, next step not", pass.wrappingUp && !pass.nextStepAgreed)
    }
```

(`Insight` has `var isHandled = false` after `createdAt`; if the memberwise init won't take `isHandled:` because of the `let createdAt = Date()` ordering, create it and set `.isHandled = true` on a `var`.)

- [ ] **Step 2: Run** `swift build 2>&1 | tail -3`. Expected: FAIL, `nudgePass` missing.

- [ ] **Step 3: Implement.** In `systemPrompt`, after the `- "read": one word for the room.` line:

```
        - "wrapping_up": true only when the conversation is clearly heading to its end \
        (thanks and goodbyes, "let's wrap up", booking the next talk). Otherwise false.
        - "next_step_agreed": true once both sides have agreed a concrete next step \
        (a follow-up meeting, a date, who sends what). Otherwise false.
```

In `schema`, add to `sentProps`:

```swift
            "wrapping_up": ["type": "boolean", "description": "The conversation is clearly heading to its end."],
            "next_step_agreed": ["type": "boolean", "description": "Both sides agreed a concrete next step."],
```

and make the sentiment `required` `["coach", "score", "read", "wrapping_up", "next_step_agreed"]`. The parser already maps JSON booleans to 1/0 through `v as? Int`; if the test shows otherwise, add `else if let b = v as? Bool { sentiment[k] = b ? 1 : 0 }` after the Int branch.

In `CallAnalysisEngine` (near `onInsightInserted`):

```swift
    static let wrappingUpKey = "wrapping_up"
    static let nextStepKey = "next_step_agreed"
    /// Insight kinds that mean "they asked and it's still open".
    static let questionKinds: Set<String> = ["question", "unanswered_question"]

    /// After every successful pass: gauges, open items and the wrap-up flags
    /// for live nudges and the report's mood line.
    @ObservationIgnored var onPassCompleted: ((NudgeDetector.Pass) -> Void)?

    nonisolated static func nudgePass(time: TimeInterval, sentiment: [String: Int], insights: [Insight],
                                      gauges: [SentimentGauge], pinnedKinds: Set<String>) -> NudgeDetector.Pass {
        let keys = Set(gauges.map(\.key))
        let open = insights.filter { !$0.isHandled && $0.kindKey != Insight.docExcerptKind }
        return NudgeDetector.Pass(
            time: time,
            values: sentiment.filter { keys.contains($0.key) },
            openQuestions: open.filter { questionKinds.contains($0.kindKey) }.map { .init(title: $0.title, since: $0.callTime) },
            openItems: open.filter { pinnedKinds.contains($0.kindKey) }.map(\.title),
            wrappingUp: sentiment[wrappingUpKey] == 1,
            nextStepAgreed: sentiment[nextStepKey] == 1)
    }
```

(If `onInsightInserted` is not `@ObservationIgnored`, match its declaration style.) At the end of the success path in `runAnalysis`, just before `status = .listening`:

```swift
            onPassCompleted?(Self.nudgePass(time: anchorTime, sentiment: merged, insights: insights,
                                            gauges: profile?.gauges ?? [],
                                            pinnedKinds: Set(profile?.kinds.filter(\.isPinned).map(\.key) ?? [])))
```

- [ ] **Step 4: Run** `make test 2>&1 | grep -E 'flags:|prompt|schema|ALL PASS|FAIL'`. Expected: all PASS, `ALL PASS`.
- [ ] **Step 5: Commit** `git commit -am "Copilot: says when the call is wrapping up and hands each pass to nudges"`

---

### Task 6: LiveNudgeSession, the audio clock and RecordingManager wiring

**Files:**
- Create: `Parrot/Services/LiveNudgeSession.swift`
- Modify: `Parrot/Services/TranscriptionEngine.swift` (`appendedSamples`, `heardSamples`, `speechClock()`, reset in `startTranscribing`)
- Modify: `Parrot/Services/RecordingManager.swift` (property, start, onSegment, timer, stop, and any discard path)
- Test: `testNudgeSession`

**Interfaces:**
- Produces: `LiveNudgeSession { static let defaultsKey = "liveNudges"; static var isEnabled: Bool; private(set) var current: Nudge?; var onShow: ((Nudge) -> Void)?; func start(gauges:nudging:); func add(line:); func add(pass:); func tick(now:lastHeard:paused:); func dismiss(); func stop() -> (nudges: [Nudge], timeline: MoodTimeline?) }`, `TranscriptionEngine.speechClock() -> (now: TimeInterval, lastHeard: [AudioSource: TimeInterval])`, `RecordingManager.nudges: LiveNudgeSession`.

- [ ] **Step 1: Failing test** (register; it's `@MainActor`):

```swift
    @MainActor
    static func testNudgeSession() {
        let session = LiveNudgeSession()
        var shown: [Nudge] = []
        session.onShow = { shown.append($0) }
        session.start(gauges: [upset], nudging: true)
        backAndForth().forEach { session.add(line: $0) }
        session.add(line: said(.me, 125, 130, "the price goes up in January"))
        session.tick(now: 140, lastHeard: [.me: 130, .them: 119], paused: true)
        check("session: paused Copilot → no nudges", session.current == nil && shown.isEmpty)
        session.tick(now: 141, lastHeard: [.me: 130, .them: 119], paused: false)
        check("session: shows and tells the pill", session.current?.kind == .goneQuiet && shown.count == 1)
        session.dismiss()
        check("session: dismiss clears the banner", session.current == nil)
        session.add(pass: NudgeDetector.Pass(time: 150, values: ["f": 30]))
        let saved = session.stop()
        check("session: stop returns nudges and mood", saved.nudges.count == 1 && saved.timeline?.snapshots.count == 1)
        let off = LiveNudgeSession()
        off.start(gauges: [upset], nudging: false)
        off.add(line: said(.me, 125, 130)); off.add(pass: NudgeDetector.Pass(time: 150, values: ["f": 30]))
        off.tick(now: 200, lastHeard: [:], paused: false)
        let offSaved = off.stop()
        check("session: switched off still keeps the mood line", offSaved.nudges.isEmpty && offSaved.timeline?.snapshots.count == 1)
    }
```

- [ ] **Step 2: Run** `swift build 2>&1 | tail -3`. Expected: FAIL, `LiveNudgeSession` missing.

- [ ] **Step 3: Implement** `Parrot/Services/LiveNudgeSession.swift`:

```swift
import Foundation
import Observation

/// One call's live nudges: owns the detector, the Copilot's mood snapshots
/// and the nudge on screen. RecordingManager feeds it; the Copilot panel's
/// banner reads `current`, the floating pill listens to `onShow`.
@MainActor
@Observable
final class LiveNudgeSession {
    static let defaultsKey = "liveNudges"
    /// On unless turned off in Settings → Copilot → Live Nudges.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    /// The latest nudge shown, until dismissed or replaced.
    private(set) var current: Nudge?
    @ObservationIgnored var onShow: ((Nudge) -> Void)?
    @ObservationIgnored private var detector = NudgeDetector()
    @ObservationIgnored private var gauges: [SentimentGauge] = []
    @ObservationIgnored private var snapshots: [MoodSnapshot] = []
    @ObservationIgnored private var nudging = false
    @ObservationIgnored private var active = false

    func start(gauges: [SentimentGauge], nudging: Bool = LiveNudgeSession.isEnabled) {
        detector = NudgeDetector(gauges: gauges)
        self.gauges = gauges
        snapshots = []
        current = nil
        self.nudging = nudging
        active = true
    }

    func add(line: NudgeDetector.Line) {
        guard active, !line.text.isEmpty else { return }
        detector.add(line)
    }

    /// The mood line is kept even with nudges off: it's the report's, not the pill's.
    func add(pass: NudgeDetector.Pass) {
        guard active else { return }
        if !pass.values.isEmpty { snapshots.append(MoodSnapshot(time: pass.time, values: pass.values)) }
        detector.add(pass)
    }

    func tick(now: TimeInterval, lastHeard: [AudioSource: TimeInterval], paused: Bool) {
        guard active, nudging, !paused, let nudge = detector.tick(now: now, lastHeard: lastHeard) else { return }
        current = nudge
        onShow?(nudge)
    }

    func dismiss() {
        current = nil
    }

    /// Ends the call: what to save on the meeting.
    func stop() -> (nudges: [Nudge], timeline: MoodTimeline?) {
        active = false
        current = nil
        return (detector.all, snapshots.isEmpty ? nil : MoodTimeline(gauges: gauges, snapshots: snapshots))
    }
}
```

`TranscriptionEngine` — next to `lastSpeechAt`:

```swift
    /// Per stream: samples appended so far, and the count at the last buffer
    /// with speech-level energy (both guarded by bufferLock). Live nudges read
    /// them through `speechClock()`, on the same clock as segment timestamps.
    private var appendedSamples: [AudioSource: Int] = [:]
    private var heardSamples: [AudioSource: Int] = [:]
```

In `appendAudio`, inside `if isTranscribing, frameCount > 0 {`, after computing `energy` and `floor`:

```swift
            bufferLock.withLock {
                let total = (appendedSamples[source] ?? 0) + frameCount
                appendedSamples[source] = total
                if energy > floor { heardSamples[source] = total }
            }
```

New method:

```swift
    /// "Now" and when each stream last carried speech, in seconds into the
    /// call on the segments' own clock (samples / 16 kHz + the stream's offset).
    func speechClock() -> (now: TimeInterval, lastHeard: [AudioSource: TimeInterval]) {
        bufferLock.withLock {
            var now: TimeInterval = 0
            var heard: [AudioSource: TimeInterval] = [:]
            for source in AudioSource.allCases {
                let offset = localClockOffset[source] ?? 0
                if let n = appendedSamples[source] { now = max(now, Double(n) / 16000 + offset) }
                if let h = heardSamples[source] { heard[source] = Double(h) / 16000 + offset }
            }
            return (now, heard)
        }
    }
```

In `startTranscribing`, inside the existing `bufferLock.withLock { … consumedSamples = … }`, add `appendedSamples = [:]; heardSamples = [:]`.

`RecordingManager`:
- Property next to `callAnalysisEngine`: `let nudges = LiveNudgeSession()`.
- In `startRecording`, before `callAnalysisEngine.start(...)`:

```swift
        nudges.start(gauges: profile?.gauges ?? [])
        nudges.onShow = { [weak self] nudge in
            guard let self else { return }
            // The banner covers it when Parrot is in front with Copilot showing.
            if !(NSApp.isActive && self.callAnalysisEngine.isActive) { NudgePillController.shared.show(nudge) }
        }
        NudgePillController.shared.onOpen = {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain && $0.isVisible }?.makeKeyAndOrderFront(nil)
        }
        callAnalysisEngine.onPassCompleted = { [weak self] pass in self?.nudges.add(pass: pass) }
```

- In `onSegment`, after `addSegment(result)`:

```swift
                self?.nudges.add(line: NudgeDetector.Line(source: result.source, start: result.startTime,
                                                          end: result.endTime, text: result.text))
```

- In the 1 s timer, after `self.elapsedTime = …`:

```swift
                let clock = self.transcriptionEngine.speechClock()
                self.nudges.tick(now: clock.now, lastHeard: clock.lastHeard, paused: self.callAnalysisEngine.isPaused)
```

- In `stopRecording`, inside `if let meeting = currentMeeting {` right after `meeting.status = .processing`:

```swift
            let tone = nudges.stop()
            meeting.nudges = tone.nudges
            meeting.moodTimeline = tone.timeline
```

  and right after `timer = nil`: `NudgePillController.shared.hide()`.
- Any other path that ends a recording without `stopRecording` (search `isRecording = false`): call `_ = nudges.stop()` and `NudgePillController.shared.hide()` there too.

(`NudgePillController` arrives in Task 7; to keep this task building, add Task 7's file first or temporarily comment the three pill lines and restore them in Task 7.)

- [ ] **Step 4: Run** `make test 2>&1 | grep -E 'session:|ALL PASS|FAIL'`. Expected: PASS, `ALL PASS`.
- [ ] **Step 5: Commit** `git add -A Parrot && git commit -m "Nudges: one session per call, fed by the recording on the audio clock"`

---

### Task 7: The pill, the Copilot banner and the setting

**Files:**
- Create: `Parrot/Views/NudgePill.swift` (`NudgePillController`, `NudgePillView`, `NudgeBanner`)
- Modify: `Parrot/Views/Theme.swift` (`Colors.nudge`, `Colors.nudgeLine`, `Colors.meLane`, `Colors.themLane`, `Colors.moodLine`, `Metrics.pillWidth`, `Metrics.pillRadius`)
- Modify: `Parrot/Views/CopilotPanelView.swift` (banner above `coachCard` in `feedArea`)
- Modify: `Parrot/Views/SettingsView.swift` (`@AppStorage(LiveNudgeSession.defaultsKey) liveNudges = true`; "Live Nudges" card after "Live Call Copilot")

- [ ] **Step 1: Theme tokens** in `Theme.Colors`:

```swift
        /// Live nudge banner fill and edge.
        static let nudge = warn.opacity(0.12)
        static let nudgeLine = warn.opacity(0.4)
        /// Tone timeline: you, them, and the mood line.
        static let meLane = ink3
        static let themLane = accent.opacity(0.6)
        static let moodLine = warn
```

and `Theme.Metrics`: `static let pillWidth: CGFloat = 460` and `static let pillRadius: CGFloat = 22`.

- [ ] **Step 2: Implement** `Parrot/Views/NudgePill.swift`:

```swift
import AppKit
import SwiftUI

/// The floating pill: one nudge over every app, full-screen calls included,
/// for about 10 seconds. A non-activating panel, so the call app keeps the
/// keyboard, and left out of screen capture so a screen share never shows
/// the other side what Parrot noticed.
@MainActor
final class NudgePillController {
    static let shared = NudgePillController()
    static let visibleFor: TimeInterval = 10

    /// Brings Parrot forward on the live call (set by RecordingManager).
    var onOpen: (() -> Void)?
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var hovering = false
    private var generation = 0

    func show(_ nudge: Nudge) {
        generation += 1
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: NudgePillView(
            nudge: nudge,
            onOpen: { [weak self] in self?.hide(); self?.onOpen?() },
            onDismiss: { [weak self] in self?.hide() },
            onHover: { [weak self] inside in self?.hover(inside) }))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.setContentSize(size)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        scheduleHide()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible else { return }
        let fading = generation
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A newer nudge may have arrived during the fade.
                if self?.generation == fading { panel.orderOut(nil) }
            }
        })
    }

    private func hover(_ inside: Bool) {
        hovering = inside
        if inside { hideTask?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.visibleFor))
            guard !Task.isCancelled, let self, !self.hovering else { return }
            self.hide()
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Theme.Metrics.pillWidth, height: 48),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        return panel
    }
}

struct NudgePillView: View {
    let nudge: Nudge
    var onOpen: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: nudge.kind.symbol)
                .foregroundStyle(Theme.Colors.warn)
            Text(nudge.text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(Theme.Typography.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.ink3)
            .help("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: Theme.Metrics.pillWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Metrics.pillRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.pillRadius).strokeBorder(Theme.Colors.nudgeLine))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.pillRadius))
        .onTapGesture(perform: onOpen)
        .onHover(perform: onHover)
    }
}

/// The same nudge inside the Copilot panel, above the coach line, until
/// dismissed or replaced.
struct NudgeBanner: View {
    let nudge: Nudge
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: nudge.kind.symbol)
                .foregroundStyle(Theme.Colors.warn)
            Text(nudge.text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(Theme.Typography.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.ink3)
            .help("Dismiss")
        }
        .padding(10)
        .background(Theme.Colors.nudge, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.nudgeLine))
    }
}
```

- [ ] **Step 3: Banner in the panel.** In `CopilotPanelView.feedArea`, before `coachCard`:

```swift
            if let nudge = recordingManager.nudges.current {
                NudgeBanner(nudge: nudge) { recordingManager.nudges.dismiss() }
                    .padding(.horizontal, Theme.Metrics.pad)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
```

- [ ] **Step 4: Setting.** In `SettingsView`: `@AppStorage(LiveNudgeSession.defaultsKey) private var liveNudges = true`, and after the "Live Call Copilot" card:

```swift
            SettingsCard(title: "Live Nudges") {
                SettingsToggleRow(
                    title: "Show live nudges",
                    detail: "Short tips during a call, like when they've gone quiet after something you said. Works without Copilot too.",
                    first: true,
                    isOn: $liveNudges
                )
            }
```

- [ ] **Step 5: Build and test.** `make test 2>&1 | tail -2` → `ALL PASS`.
- [ ] **Step 6: Commit** `git add -A Parrot && git commit -m "Nudges: the floating pill, the Copilot banner and the setting"`

---

### Task 8: The report card

**Files:**
- Create: `Parrot/Views/ToneTimelineCard.swift`
- Modify: `Parrot/Views/MeetingDetailView.swift` (`reportTab`: both branches)

- [ ] **Step 1: Implement** `Parrot/Views/ToneTimelineCard.swift`:

```swift
import SwiftUI

/// "How the call went": talk bars per minute, the main gauge over time and
/// numbered moments (nudges, turning points, marks) you can play.
struct ToneTimelineCard: View, Equatable {
    let model: ToneTimeline.Model
    var play: ((TimeInterval) -> Void)?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model == rhs.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("How the call went").font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink)
                Spacer()
                Text(Receipts.stamp(model.duration)).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ink3)
            }
            HStack(spacing: 10) {
                tile("You talked", model.talkPercentMe.map { "\($0)%" } ?? "–")
                tile("Key moments", "\(model.moments.count)")
                if let gauge = model.gauge, let end = model.endLevel { tile("\(gauge.label) at the end", end) }
            }
            legend
            chart.frame(height: 150)
            if !model.moments.isEmpty {
                VStack(spacing: 0) { ForEach(model.moments) { row($0) } }
            }
        }
        .padding(14)
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius).strokeBorder(Theme.Colors.line))
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ink2)
            Text(value).font(Theme.Typography.sans(17, .semibold)).foregroundStyle(Theme.Colors.ink)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.chip.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            swatch(Theme.Colors.meLane, "You")
            swatch(Theme.Colors.themLane, "Them")
            if let gauge = model.gauge { swatch(Theme.Colors.moodLine, gauge.label) }
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.Colors.ink2)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    private static func color(_ kind: ToneTimeline.Moment.Kind) -> Color {
        switch kind {
        case .nudge: Theme.Colors.warn
        case .turn: Theme.Colors.accent
        case .mark: Theme.Colors.ink2
        }
    }

    private var chart: some View {
        Canvas { ctx, size in
            let left: CGFloat = 38, right: CGFloat = 8
            let width = max(1, size.width - left - right)
            let duration = max(model.duration, 1)
            func x(_ t: TimeInterval) -> CGFloat { left + CGFloat(min(t, duration) / duration) * width }
            let barH: CGFloat = 28, moodTop: CGFloat = 40, moodH: CGFloat = 68, markY: CGFloat = 124

            ctx.draw(Text("Talk").font(Theme.Typography.caption).foregroundColor(Theme.Colors.ink3),
                     at: CGPoint(x: 0, y: barH / 2), anchor: .leading)
            let slot = width / CGFloat(model.minutes.count)
            for (i, m) in model.minutes.enumerated() where m.me + m.them > 0 {
                let meH = barH * CGFloat(m.me / (m.me + m.them))
                let bx = left + CGFloat(i) * slot + 1, bw = max(1, slot - 2)
                ctx.fill(Path(roundedRect: CGRect(x: bx, y: 0, width: bw, height: meH), cornerRadius: 1.5),
                         with: .color(Theme.Colors.meLane))
                ctx.fill(Path(roundedRect: CGRect(x: bx, y: meH, width: bw, height: barH - meH), cornerRadius: 1.5),
                         with: .color(Theme.Colors.themLane))
            }

            if let gauge = model.gauge, model.mood.count >= 2 {
                ctx.draw(Text(gauge.highLabel).font(Theme.Typography.caption).foregroundColor(Theme.Colors.ink3),
                         at: CGPoint(x: 0, y: moodTop), anchor: .leading)
                ctx.draw(Text(gauge.lowLabel).font(Theme.Typography.caption).foregroundColor(Theme.Colors.ink3),
                         at: CGPoint(x: 0, y: moodTop + moodH), anchor: .leading)
                var mid = Path()
                mid.move(to: CGPoint(x: left, y: moodTop + moodH / 2))
                mid.addLine(to: CGPoint(x: left + width, y: moodTop + moodH / 2))
                ctx.stroke(mid, with: .color(Theme.Colors.line), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                var line = Path()
                for (i, p) in model.mood.enumerated() {
                    let point = CGPoint(x: x(p.time), y: moodTop + moodH * (1 - CGFloat(p.value) / 100))
                    if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                ctx.stroke(line, with: .color(Theme.Colors.moodLine), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }

            for m in model.moments {
                let cx = x(m.time)
                var tick = Path()
                tick.move(to: CGPoint(x: cx, y: barH))
                tick.addLine(to: CGPoint(x: cx, y: markY - 9))
                ctx.stroke(tick, with: .color(Theme.Colors.line), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                let tint = Self.color(m.kind)
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 9, y: markY - 9, width: 18, height: 18)), with: .color(tint.opacity(0.18)))
                ctx.draw(Text("\(m.number)").font(Theme.Typography.caption).foregroundColor(tint), at: CGPoint(x: cx, y: markY))
            }

            let step: TimeInterval = duration > 1800 ? 600 : duration > 600 ? 300 : 60
            var t: TimeInterval = 0
            while t <= duration {
                ctx.draw(Text(Receipts.stamp(t)).font(Theme.Typography.caption).foregroundColor(Theme.Colors.ink3),
                         at: CGPoint(x: x(t), y: size.height - 6))
                t += step
            }
        }
    }

    private func row(_ m: ToneTimeline.Moment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(m.number)")
                .font(Theme.Typography.caption)
                .foregroundStyle(Self.color(m.kind))
                .frame(width: 20, height: 20)
                .background(Self.color(m.kind).opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.title).font(Theme.Typography.cardTitle).foregroundStyle(Theme.Colors.ink)
                    Text(Receipts.stamp(m.time)).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.ink3)
                }
                Text(m.detail).font(Theme.Typography.secondary).foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let play {
                Button { play(m.time) } label: { Label("Play", systemImage: "play.fill") }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }
}
```

- [ ] **Step 2: Wire into `MeetingDetailView`.** Add:

```swift
    /// The tone timeline, nil for imported audio (no "Me" track).
    private var toneModel: ToneTimeline.Model? {
        ToneTimeline.model(duration: meeting.duration, spans: ToneTimeline.spans(meeting.sortedSegments),
                           nudges: meeting.nudges, timeline: meeting.moodTimeline, marks: meeting.bookmarks)
    }
```

In `reportTab`'s empty branch, after the status row and before the bookmarks card, and in the report branch right after `AIAppsReportTip(meeting: meeting)` (so below the rewritten banner, above `ReportContentView`):

```swift
                        if let model = toneModel {
                            ToneTimelineCard(model: model,
                                             play: (audioPlayer != nil || micPlayer != nil) ? playFrom : nil)
                                .equatable()
                        }
```

- [ ] **Step 3: Build** `make test 2>&1 | tail -2` → `ALL PASS`.
- [ ] **Step 4: Commit** `git add -A Parrot && git commit -m "Report: How the call went, the tone timeline card"`

---

### Task 9: Harnesses — `--nudge-replay` and `--tone-snapshot`

**Files:**
- Create: `Parrot/ToneHarness.swift` (`NudgeReplay`, `ToneSnapshot`)
- Modify: `Parrot/ParrotApp.swift` (two flags, next to `--copilot-replay`)
- Test: `testNudgeReplay`

- [ ] **Step 1: Failing test** (register):

```swift
    static func testNudgeReplay() {
        let lines = backAndForth() + [said(.me, 125, 130, "the price goes up in January")]
        let nudges = NudgeReplay.replay(lines: lines, timeline: nil, duration: 200)
        check("replay: finds the silence after your line", nudges.contains { $0.kind == .goneQuiet && $0.time == 125 })
    }
```

- [ ] **Step 2: Implement** `Parrot/ToneHarness.swift`:

```swift
import AppKit
import SwiftData
import SwiftUI

/// `Parrot --nudge-replay [meeting-id-prefix]`: replays saved calls (default:
/// the newest) through the live nudge rules second by second and prints every
/// nudge with its time and whether it would have shown. For tuning
/// `NudgeDetector.Tuning` on real calls. Read-only on the store. Copilot-only
/// rules (unanswered question, wrap-up) can't replay: open cards and the
/// wrap-up flag aren't saved; mood shift replays from the saved mood line.
@MainActor
enum NudgeReplay {
    static func run(args: [String]) {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
        guard let container = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, allowsSave: false)]) else {
            print("nudge-replay: can't open the store"); exit(1)
        }
        let all = (try? ModelContext(container).fetch(FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        let picked = args.first.map { p in all.filter { $0.id.uuidString.lowercased().hasPrefix(p.lowercased()) } } ?? Array(all.prefix(1))
        guard !picked.isEmpty else { print("nudge-replay: no matching meeting"); exit(1) }
        for meeting in picked {
            let lines = meeting.sortedSegments.map {
                NudgeDetector.Line(source: $0.speakerLabel == "Me" ? .me : .them, start: $0.startTime, end: $0.endTime, text: $0.text)
            }
            let nudges = replay(lines: lines, timeline: meeting.moodTimeline, duration: meeting.duration)
            print("\(meeting.title) (\(meeting.id.uuidString.prefix(8))) · \(Receipts.stamp(meeting.duration)) · \(lines.count) lines · \(nudges.count) nudges")
            for n in nudges {
                print("  [\(Receipts.stamp(n.time))] \(n.shown ? "shown" : "held ") \(n.kind.rawValue): \(n.text)")
            }
        }
        exit(0)
    }

    /// Lines arrive 1 s after they end (decode time); a track counts as
    /// heard while one of its lines is in progress.
    static func replay(lines: [NudgeDetector.Line], timeline: MoodTimeline?, duration: TimeInterval) -> [Nudge] {
        var detector = NudgeDetector(gauges: timeline?.gauges ?? [])
        var waiting = lines.sorted { $0.end < $1.end }
        var passes = timeline?.snapshots ?? []
        var heard: [AudioSource: TimeInterval] = [:]
        let end = max(duration, lines.map(\.end).max() ?? 0) + 30
        var t: TimeInterval = 0
        while t <= end {
            while let line = waiting.first, line.end + 1 <= t { detector.add(line); waiting.removeFirst() }
            while let pass = passes.first, pass.time <= t {
                detector.add(NudgeDetector.Pass(time: pass.time, values: pass.values))
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
}

/// `Parrot --tone-snapshot /tmp/tone.png`: renders the report card (with and
/// without a mood line), the pill and the banner, light and dark ("-dark").
@MainActor
enum ToneSnapshot {
    static func write(to path: String) {
        let gauge = SentimentGauge(id: UUID(), key: "buying_temperature", label: "Buying temp", lowLabel: "Cold", highLabel: "Hot", colorHex: "E8943A")
        var spans: [ToneTimeline.Span] = []
        var t: TimeInterval = 0
        while t < 1920 {
            spans.append(.init(isMe: true, start: t, end: t + 20, text: "you talk here"))
            spans.append(.init(isMe: false, start: t + 22, end: t + 40, text: "they answer here"))
            t += 45
        }
        spans.append(.init(isMe: true, start: 755, end: 762, text: "the price goes up in January"))
        let mood = [(0, 50), (240, 55), (480, 60), (720, 62), (780, 36), (900, 30), (1140, 38), (1265, 62), (1500, 70), (1740, 66), (1920, 75)]
            .map { MoodSnapshot(time: TimeInterval($0.0), values: [gauge.key: $0.1]) }
        let nudges = [
            Nudge(kind: .longMonologue, time: 250, text: "You've been talking for 2 minutes. Check in?"),
            Nudge(kind: .goneQuiet, time: 755, text: "They've gone quiet since you said \u{201C}the price goes up in January\u{201D}"),
            Nudge(kind: .talkingOver, time: 1590, text: "You've talked over them 3 times. Let them finish", shown: false),
        ]
        let withMood = ToneTimeline.model(duration: 1920, spans: spans, nudges: nudges,
                                          timeline: MoodTimeline(gauges: [gauge], snapshots: mood), marks: [])!
        let plain = ToneTimeline.model(duration: 1920, spans: spans, nudges: Array(nudges.prefix(2)), timeline: nil,
                                       marks: [Bookmark(time: 1300, label: "pilot offer")])!
        let view = VStack(alignment: .leading, spacing: 16) {
            NudgePillView(nudge: nudges[1])
            NudgeBanner(nudge: nudges[1], onDismiss: {}).frame(width: 420)
            ToneTimelineCard(model: withMood, play: { _ in })
            ToneTimelineCard(model: plain, play: nil)
        }
        .padding(20)
        .frame(width: 720)
        .background(Theme.Colors.panel)
        let light = render(view, dark: false, to: path)
        let dark = render(view, dark: true, to: (path as NSString).deletingPathExtension + "-dark.png")
        FileHandle.standardError.write(Data("tone-snapshot: wrote \(light.path) + \(dark.path)\n".utf8))
        exit(0)
    }

    private static func render(_ view: some View, dark: Bool, to path: String) -> URL {
        let renderer = ImageRenderer(content: AnyView(view.environment(\.colorScheme, dark ? .dark : .light)))
        renderer.scale = 2
        var cg: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { cg = renderer.cgImage }
        guard let cg, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("tone-snapshot: render failed\n".utf8)); exit(1)
        }
        return SnapshotIO.write(data, to: path)
    }
}
```

In `ParrotApp.main`, next to `--copilot-replay`:

```swift
        if let i = args.firstIndex(of: "--nudge-replay") {
            MainActor.assumeIsolated { NudgeReplay.run(args: Array(args[(i + 1)...])) }
            return
        }
        if let i = args.firstIndex(of: "--tone-snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { ToneSnapshot.write(to: args[i + 1]) }
            return
        }
```

- [ ] **Step 3: Run** `make test 2>&1 | grep -E 'replay:|ALL PASS|FAIL'` → PASS. Then `swift build && .build/debug/Parrot --tone-snapshot /tmp/parrot-tone.png`; open both PNGs and check: bars, mood line, numbered markers, list rows, pill, banner, readable in light and dark. Then `.build/debug/Parrot --nudge-replay` on the latest real call and read the output for obviously wrong nudges; adjust `Tuning` only with a failing test first.
- [ ] **Step 4: Commit** `git add -A Parrot && git commit -m "Harness: --nudge-replay and --tone-snapshot"`

---

### Task 10: Docs, project file, final verification

**Files:**
- Modify: `FILEMAP.md` (new rows: `Models/Nudge.swift`, `Services/NudgeDetector.swift`, `Services/LiveNudgeSession.swift`, `Services/ToneTimeline.swift`, `Views/NudgePill.swift`, `Views/ToneTimelineCard.swift`, `ToneHarness.swift`, `ProfileTest+Nudges.swift`; harness list gains `--nudge-replay`, `--tone-snapshot`)
- Modify: `CLAUDE.md` (harness flag list)
- Modify: `docs/help/copilot-live.html` (a "Live nudges" section), `docs/help/reports.html` (a "How the call went" section)
- Regenerate: `Parrot.xcodeproj` via `make xcode`

- [ ] **Step 1:** Update FILEMAP rows (line counts from `wc -l`), CLAUDE.md flag list, and the two help pages (plain English, short: what each nudge means, the one setting, that nothing reads emotion from voices, that the pill never shows in a screen share).
- [ ] **Step 2:** `make xcode` and confirm `git diff --stat Parrot.xcodeproj` lists the new files.
- [ ] **Step 3:** `make test 2>&1 | tail -3` → `ALL PASS`. `make` → builds `dist/Parrot.app`.
- [ ] **Step 4: Commit** `git add -A && git commit -m "Docs: live nudges and the tone timeline"`

---

## Manual checks (owner, needs a real call)

- Screen share in Zoom and in Meet while a nudge shows: the pill must not appear in the share (`sharingType = .none`).
- Full-screen Zoom: the pill appears on top; typing stays in Zoom.
- Copilot paused: no nudges. Setting off: no nudges, report still has the mood line.
