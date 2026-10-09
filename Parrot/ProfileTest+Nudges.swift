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
        m.moodTimeline = MoodTimeline(gauges: [upset], snapshots: [MoodSnapshot(time: 10, values: ["f": 40])])
        check("nudge: mood timeline round trip", m.moodTimeline?.snapshots.first?.values["f"] == 40)
        m.moodTimeline = MoodTimeline(gauges: [upset], snapshots: [])
        check("nudge: empty timeline clears the field", m.moodTimelineData == nil)
    }

    // MARK: - Helpers

    private static let upset = SentimentGauge(id: UUID(), key: "f", label: "Frustration", lowLabel: "Calm",
                                              highLabel: "Upset", colorHex: "E8943A")

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
            return [said(.me, t, t + 5, "what about \(topic) plans"),
                    said(.them, t + 5 + gap, t + 10 + gap, "\(topic) looks fine")]
        }
    }

    // MARK: - Timing rules

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
        check("quiet: a slow speaker gets 3x their gap", slow.tick(now: 163, lastHeard: [.me: 155, .them: 149]) == nil)
        check("quiet: …and then it fires", slow.tick(now: 167.5, lastHeard: [.me: 155, .them: 149])?.kind == .goneQuiet)

        // Long monologue: 90 s of you after their last line, still talking.
        var mono = NudgeDetector()
        mono.add(said(.them, 100, 110, "tell me about it"))
        mono.add(said(.me, 112, 150, "first part"))
        mono.add(said(.me, 151, 190, "second part"))
        mono.add(said(.me, 191, 205, "third part"))
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

        // Short answers: 4 short replies after long ones.
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
        fast.add(said(.me, 400, 410, words(40)))
        fast.add(said(.me, 412, 422, words(40)))
        check("speeding up: fires at 1.6x", fast.tick(now: 423, lastHeard: [:])?.kind == .speedingUp)
        check("speeding up: not again while still fast", fast.tick(now: 424, lastHeard: [:]) == nil)

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
        early.add(said(.them, 10, 12))
        early.add(said(.me, 20, 25))
        check("warm-up: silent before 2 min", early.tick(now: 60, lastHeard: [.me: 25, .them: 12]) == nil && early.all.isEmpty)

        check("short: whole words + ellipsis", NudgeDetector.short("one two three four", max: 10) == "one two\u{2026}")
        check("median: even count", NudgeDetector.median([1, 2, 3, 4]) == 2.5)
    }

    // MARK: - Report maths

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
        let talk = SentimentGauge(id: UUID(), key: "my_dominance", label: "You're talking", lowLabel: "Balanced",
                                  highLabel: "Dominating", colorHex: "5F6470")
        check("timeline: main gauge skips talk balance", TT.mainGauge([talk, upset])?.key == "f")
        check("timeline: level words", TT.level(10, upset) == "Calm" && TT.level(90, upset) == "Upset" && TT.level(50, upset) == "In between")
        let snaps = [MoodSnapshot(time: 40, values: ["f": 20]), MoodSnapshot(time: 60, values: ["f": 30]),
                     MoodSnapshot(time: 80, values: ["f": 70]), MoodSnapshot(time: 95, values: ["f": 30])]
        let turns = TT.turningPoints(snaps, gauge: upset, spans: spans)
        check("timeline: two turning points", turns.count == 2)
        check("timeline: quotes the wordiest line between passes",
              turns.first?.text == "Frustration moved toward Upset after \u{201C}we can't do that date\u{201D}")
        check("timeline: no line between → pass time, no quote", turns.last?.time == 95 && turns.last?.quote == nil)
        let shift = Nudge(kind: .moodShift, time: turns[0].time, text: "shift")
        let quiet = Nudge(kind: .goneQuiet, time: 10, text: "quiet")
        let moments = TT.moments(nudges: [shift, quiet], turns: turns, marks: [Bookmark(time: 90, label: "price")])
        check("timeline: moments numbered by time", moments.map(\.number) == [1, 2, 3, 4] && moments.map(\.time) == [10, 50, 90, 95])
        check("timeline: a mood-shift nudge hides its duplicate turn", moments.filter { $0.kind == .turn }.count == 1)
        check("timeline: no card without both sides", TT.model(duration: 60, spans: [spans[1]], nudges: [], timeline: nil, marks: []) == nil)
        let model = TT.model(duration: 150, spans: spans, nudges: [],
                             timeline: MoodTimeline(gauges: [upset], snapshots: snaps), marks: [])
        check("timeline: model carries the mood line", model?.mood.count == 4 && model?.gauge?.key == "f" && model?.endLevel == "Calm")
        let noMood = TT.model(duration: 150, spans: spans, nudges: [], timeline: nil, marks: [])
        check("timeline: no Copilot → bars only", noMood?.gauge == nil && noMood?.mood.isEmpty == true && noMood?.minutes.count == 4)
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

    // MARK: - Copilot rules

    static func testNudgeCopilotRules() {
        var d = NudgeDetector(gauges: [upset])
        d.add(NudgeDetector.Pass(time: 150, values: ["f": 20]))
        d.add(said(.me, 155, 160, "we can't do that date sorry"))
        d.add(said(.them, 161, 162, "ok"))
        d.add(NudgeDetector.Pass(time: 170, values: ["f": 60]))
        let shift = d.tick(now: 171, lastHeard: [.them: 170, .me: 170])
        check("mood: fires on a 25+ move", shift?.kind == .moodShift)
        check("mood: same words as the report",
              shift?.text == "Frustration moved toward Upset after \u{201C}we can't do that date sorry\u{201D}")

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
        check("limiter: warm-up drops early nudges",
              d.tick(now: 61, lastHeard: [:]) == nil && d.tick(now: 130, lastHeard: [:]) == nil && d.all.isEmpty)
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

    // MARK: - Copilot flags and the live session

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
        check("flags: parsed as 1/0", parsed?.sentiment["wrapping_up"] == 1 && parsed?.sentiment["next_step_agreed"] == 0
              && parsed?.sentiment["f"] == 40)
        let insights = [
            Insight(kindKey: "question", title: "Contract length?", detail: "", callTime: 90, source: nil),
            Insight(kindKey: "blocker", title: "Price too high", detail: "", callTime: 80, source: nil),
            Insight(kindKey: "question", title: "Done one", detail: "", callTime: 70, source: nil, isHandled: true),
        ]
        let pass = CallAnalysisEngine.nudgePass(time: 100, sentiment: ["f": 40, "score": 60, "wrapping_up": 1],
                                                insights: insights, gauges: [upset], pinnedKinds: ["blocker"])
        check("flags: pass keeps profile gauges only", pass.values == ["f": 40])
        check("flags: open questions, not handled ones", pass.openQuestions == [.init(title: "Contract length?", since: 90)])
        check("flags: pinned open items", pass.openItems == ["Price too high"])
        check("flags: wrap-up read, next step not", pass.wrappingUp && !pass.nextStepAgreed)
    }

    /// Calls 163 and 167: asked for every gauge, the model wrote 0 when it
    /// couldn't tell, so Fit read 0, 50, 0, 45, 0. Now it writes null, and
    /// every reader skips the gap. A real 0 is still a reading.
    @MainActor
    static func testGaugeCantTell() {
        typealias TT = ToneTimeline
        let prompt = ClaudeAnalysisProvider.systemPrompt(persona: "P", kinds: [], gauges: [upset])
        check("can't tell: prompt asks for null, never 0",
              prompt.contains("or null while nothing has yet") && prompt.contains("Never write 0"))
        let sentiment = (ClaudeAnalysisProvider.schema(kinds: [], gauges: [upset])["properties"] as? [String: Any])?["sentiment"] as? [String: Any]
        let gauge = (sentiment?["properties"] as? [String: Any])?["f"] as? [String: Any]
        check("can't tell: the schema takes a number or null for each gauge",
              (gauge?["anyOf"] as? [[String: String]])?.compactMap { $0["type"] } == ["integer", "null"]
                  && (sentiment?["required"] as? [String])?.contains("f") == true)
        let named = SentimentGauge(id: UUID(), key: "score", label: "Score", lowLabel: "Low", highLabel: "High", colorHex: "E8943A")
        let clash = (ClaudeAnalysisProvider.schema(kinds: [], gauges: [named])["properties"] as? [String: Any])?["sentiment"] as? [String: Any]
        check("can't tell: a gauge keyed like a fixed field is required once", (clash?["required"] as? [String])?.filter { $0 == "score" }.count == 1)
        let parse = { (gauge: String) in
            try? ClaudeAnalysisProvider.parseAnalysisPayload(
                #"{"insights":[],"sentiment":{"coach":"c","score":50,"read":"r","wrapping_up":false,"next_step_agreed":false"#
                    + gauge + #"},"resolved":[]}"#)
        }
        check("can't tell: left out → no value", parse("") != nil && parse("")?.sentiment["f"] == nil)
        check("can't tell: null → no value", parse(#","f":null"#) != nil && parse(#","f":null"#)?.sentiment["f"] == nil)
        check("can't tell: a real 0 is kept", parse(#","f":0"#)?.sentiment["f"] == 0)
        let pass = CallAnalysisEngine.nudgePass(time: 11, sentiment: parse("")?.sentiment ?? [:], insights: [],
                                                gauges: [upset], pinnedKinds: [])
        let session = LiveNudgeSession()
        session.start(gauges: [upset], nudging: false)
        session.add(pass: pass)
        check("can't tell: no reading, no snapshot", pass.values.isEmpty && session.stop().timeline == nil)

        // Live: a pass that left the gauge out neither fires nor hides a shift.
        var d = NudgeDetector(gauges: [upset])
        d.add(NudgeDetector.Pass(time: 150, values: ["f": 20]))
        d.add(said(.them, 155, 160, "honestly the pricing is a problem for us"))
        d.add(NudgeDetector.Pass(time: 165, values: [:]))
        check("can't tell: a gap is no mood shift", d.tick(now: 166, lastHeard: [:]) == nil)
        d.add(NudgeDetector.Pass(time: 180, values: ["f": 60]))
        let shift = d.tick(now: 181, lastHeard: [:])
        check("can't tell: a shift across the gap still fires, quoting the line since the last reading",
              shift?.kind == .moodShift && shift?.quote == "honestly the pricing is a problem for us")

        // Report: the line skips passes without the gauge and keeps a real 0.
        let spans = [TT.Span(isMe: true, start: 130, end: 140, text: "so where are we on budget"),
                     TT.Span(isMe: false, start: 150, end: 170, text: "we have none this year")]
        let snaps = [MoodSnapshot(time: 11, values: ["my_dominance": 20]), MoodSnapshot(time: 140, values: ["f": 70]),
                     MoodSnapshot(time: 160, values: ["my_dominance": 30]), MoodSnapshot(time: 200, values: ["f": 0])]
        let model = TT.model(duration: 250, spans: spans, nudges: [],
                             timeline: MoodTimeline(gauges: [upset], snapshots: snaps), marks: [])
        check("can't tell: the mood line skips the gaps, keeps the 0", model?.mood.map(\.value) == [70, 0] && model?.endLevel == "Calm")
        let turns = TT.turningPoints(snaps, gauge: upset, spans: spans)
        check("can't tell: one turning point, across the gap", turns.map { [$0.from, $0.to] } == [[70, 0]]
              && turns.first?.quote == "we have none this year")
    }

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
        off.add(line: said(.me, 125, 130))
        off.add(pass: NudgeDetector.Pass(time: 150, values: ["f": 30]))
        off.tick(now: 200, lastHeard: [:], paused: false)
        let offSaved = off.stop()
        check("session: switched off still keeps the mood line", offSaved.nudges.isEmpty && offSaved.timeline?.snapshots.count == 1)
    }

    @MainActor
    static func testNudgeReplay() {
        let lines = backAndForth() + [said(.me, 125, 130, "the price goes up in January")]
        let nudges = NudgeReplay.replay(lines: lines, timeline: nil, duration: 200)
        check("replay: finds the silence after your line", nudges.contains { $0.kind == .goneQuiet && $0.time == 125 })
        check("replay: nothing else in a normal call", nudges.count == 1)
    }
}
