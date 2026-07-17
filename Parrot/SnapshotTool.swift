import SwiftUI
import AppKit
import SwiftData
import WhisperKit

/// Dev-only: transcribes a real audio file with the production decoding options to
/// verify the output is clean (no "<|...|>" tokens, no repetition loops) without
/// having to record live. Run with:
///   Parrot --transcribe-test <audio.caf> <modelFolder>
enum TranscribeTest {
    static func run(audioPath: String, modelFolder: String) {
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let config = WhisperKitConfig(
                    modelFolder: modelFolder.isEmpty ? nil : modelFolder,
                    verbose: false,
                    logLevel: .none,
                    load: true,
                    download: modelFolder.isEmpty
                )
                let whisperKit = try await WhisperKit(config)

                var opts = DecodingOptions(task: .transcribe, language: "en")
                opts.skipSpecialTokens = true
                opts.withoutTimestamps = true
                opts.compressionRatioThreshold = 2.4
                opts.logProbThreshold = -1.0
                opts.noSpeechThreshold = 0.6
                opts.temperatureFallbackCount = 3

                let results = try await whisperKit.transcribe(audioPath: audioPath, decodeOptions: opts)
                let text = results.map(\.text).joined(separator: " ")
                let hasTokens = text.contains("<|")
                print("=== transcribe-test ===")
                print("chars: \(text.count) | contains '<|' tokens: \(hasTokens)")
                print("---")
                print(String(text.prefix(1800)))
                print("---")
            } catch {
                print("transcribe-test error: \(error)")
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
}

/// Offscreen renderer for the live copilot panel. Run with:
///   Parrot --copilot-snapshot /tmp/copilot.png
/// Renders the redesigned "glanceable" panel with seeded fake state (hero
/// suggestion, pinned blocker, history rows, sentiment chips) in light AND dark
/// (second file gets a "-dark" suffix), so the design can be eyeballed without
/// a live call. Dev-only; never reached in normal launches.
@MainActor
enum CopilotSnapshot {
    static func write(to path: String) {
        let rm = RecordingManager()
        let profile = ProfilePresets.all().first { $0.name == "Sales discovery" }

        // Newest first — index 0 becomes the hero. The unhandled objection is
        // filtered into the pinned zone regardless of position.
        let insights: [Insight] = [
            Insight(kindKey: "suggestion", title: "Answer the security question",
                    detail: "“All audio stays on your Mac — only transcript text goes to the API, and we can sign a DPA this week if that helps.”",
                    callTime: 754, source: "security-faq.pdf"),
            Insight(kindKey: "buying_signal", title: "Asked about onboarding timeline",
                    detail: "They want to know how fast the team could start — a strong intent signal.",
                    callTime: 698, source: nil),
            Insight(kindKey: "next_step", title: "Propose a pilot with the sales pod",
                    detail: "Offer a two-week pilot with the 5-person sales pod they mentioned.",
                    callTime: 645, source: nil),
            Insight(kindKey: "discovery_gap", title: "Budget owner still unknown",
                    detail: "Nobody has said who signs off — worth asking directly.",
                    callTime: 590, source: nil),
            Insight(kindKey: "objection", title: "Worried about switching costs",
                    detail: "They brought up migration effort from their current tool twice.",
                    callTime: 512, source: "onboarding-guide.pdf",
                    reply: "Our team handles the full migration in under a week — the onboarding guide has the exact checklist."),
        ]

        rm.callAnalysisEngine.seedForSnapshot(
            profile: profile,
            insights: insights,
            sentiment: ["buying_temperature": 62, "my_dominance": 55, "score": 68],
            read: "warming",
            coach: "Going well — stop listing features and ask who signs off on budget.",
            meCharacters: 1300, themCharacters: 900
        )

        let panel = CopilotPanelView(transcriptJumpTarget: .constant(nil))
            .environment(rm)
            .frame(width: 420, height: 700)

        let light = render(panel, dark: false, to: path)
        let dark = render(panel, dark: true, to: (path as NSString).deletingPathExtension + "-dark.png")

        // ImageRenderer can't lay out ScrollView contents, so the panel render
        // shows an empty history area — render the rows separately (one
        // expanded) so their design is still verifiable offscreen.
        func kindStyle(_ insight: Insight) -> KindStyle {
            KindResolver.style(forKey: insight.kindKey, profile: profile, snapshot: [])
        }
        let history = VStack(spacing: 6) {
            PinnedBlockerRow(insight: insights[4], startExpanded: true, onHandled: {}, onJump: {})
            InsightCard(insight: insights[1], kindStyle: kindStyle(insights[1]),
                        isCollapsed: true, onToggleCollapse: {}, onJump: {}, onDismiss: {})
            InsightCard(insight: insights[2], kindStyle: kindStyle(insights[2]),
                        isCollapsed: false, onToggleCollapse: {}, onJump: {}, onDismiss: {})
            InsightCard(insight: insights[3], kindStyle: kindStyle(insights[3]),
                        isCollapsed: true, onToggleCollapse: {}, onJump: {}, onDismiss: {})
        }
        .padding(12)
        .frame(width: 420)
        .background(Theme.Colors.panel)
        let rows = render(history, dark: false, to: (path as NSString).deletingPathExtension + "-history.png")

        let legendURL = render(legend(profile: profile), dark: false,
                               to: (path as NSString).deletingPathExtension + "-legend.png")

        // Chat-bubble transcript strip: two speaker groups + the typing bubble.
        let seg: (TimeInterval, String, String) -> TranscriptSegment = { start, speaker, text in
            TranscriptSegment(startTime: start, endTime: start + 4, text: text,
                              speakerLabel: speaker, confidence: nil)
        }
        let bubbleSegments = [
            seg(120, "Them", "So how would the migration from our current tool actually work?"),
            seg(124, "Them", "We have about two years of call history in there."),
            seg(129, "Me", "Great question — we handle the full export and import for you."),
            seg(134, "Me", "Usually it's done within a week, including the archive."),
        ]
        let bubbles = VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(bubbleSegments.enumerated()), id: \.offset) { index, segment in
                ChatBubbleRow(
                    segment: segment,
                    isFirstOfGroup: index == 0
                        || bubbleSegments[index - 1].speakerLabel != segment.speakerLabel
                )
            }
            TypingBubble(text: "That sounds reasonable, and what about")
                .padding(.top, 8)
        }
        .padding(12)
        .frame(width: 380)
        .background(Theme.Colors.panel)
        let bubblesURL = render(bubbles, dark: false,
                                to: (path as NSString).deletingPathExtension + "-bubbles.png")

        FileHandle.standardError.write(Data("copilot-snapshot: wrote \(light.path) + \(dark.path) + \(rows.path) + \(legendURL.path) + \(bubblesURL.path)\n".utf8))
        exit(0)
    }

    // MARK: - Card-system legend

    /// A one-image guide to the live panel: the four zones plus every card kind
    /// of the given profile, drawn with the app's real colors and icons.
    private static func legend(profile: CallProfile?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Parrot Copilot — what each card means")
                .font(Theme.Typography.title(20))
                .foregroundStyle(Theme.Colors.ink)

            Text("PANEL ZONES (top to bottom)")
                .font(Theme.Typography.cap)
                .foregroundStyle(Theme.Colors.ink3)

            legendRow(Theme.Colors.accent, "gauge.with.needle",
                      "Coach card — always on top",
                      "Live verdict: 0–100 call score, one sentence of what to do right now, mood chips, and how many blockers are open.")
            legendRow(Theme.Colors.subtle, "rectangle.inset.filled.top",
                      "Hero card — the big tinted one",
                      "The newest insight, at full size. Glows briefly when it lands. This is the one to glance at.")
            legendRow(Theme.Colors.warn, "exclamationmark.triangle.fill",
                      "Orange cards — unresolved",
                      "Objections and questions you haven't dealt with yet. Click to read all of it; ✓ marks it handled — or it clears itself when the call actually resolves it.")
            legendRow(Theme.Colors.ink3, "list.bullet",
                      "EARLIER — the quiet history",
                      "Everything older, one line each. Click any row to expand it.")

            Divider().overlay(Theme.Colors.line)

            Text("CARD KINDS IN THIS PROFILE (\(profile?.name ?? "Default"))")
                .font(Theme.Typography.cap)
                .foregroundStyle(Theme.Colors.ink3)

            ForEach(profile?.kinds ?? [], id: \.id) { kind in
                legendRow(KindResolver.adaptiveColor(forHex: kind.colorHex),
                          kind.iconSystemName, kind.label,
                          legendBlurb(for: kind.key))
            }
        }
        .padding(Theme.Metrics.pad)
        .frame(width: 480)
        .background(Theme.Colors.canvas)
    }

    private static func legendRow(_ color: Color, _ icon: String,
                                  _ title: String, _ blurb: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: Theme.Metrics.radius)
                .fill(color.opacity(0.16))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(color))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.ink)
                Text(blurb)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Plain-language one-liner per sales-profile kind key (falls back to the
    /// kind's own trigger text for custom kinds).
    private static func legendBlurb(for key: String) -> String {
        switch key {
        case "suggestion": "A line you can literally say, right now. The Copy button puts it on your clipboard."
        case "objection": "They pushed back (price, timing, competitor) and it isn't settled yet. Stays orange until handled."
        case "unanswered_question": "They asked you something and the conversation moved on — circle back to it."
        case "opportunity": "They revealed a pain or goal your offer can solve — how to position it."
        case "buying_signal": "A sign they're interested — the moment to advance the deal."
        case "next_step": "A concrete step to propose or confirm (pilot, follow-up call, intro)."
        case "discovery_gap": "Something important you don't know yet — the card is the question to ask next."
        default: "Custom card defined in this profile's settings."
        }
    }

    private static func render(_ view: some View, dark: Bool, to path: String) -> URL {
        let renderer = ImageRenderer(
            content: AnyView(view.environment(\.colorScheme, dark ? .dark : .light)))
        renderer.scale = 2
        // Theme colors resolve through NSColor(name:) providers, which follow the
        // current *drawing* appearance — set it explicitly per render.
        var cg: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            cg = renderer.cgImage
        }
        guard let cg else {
            FileHandle.standardError.write(Data("copilot-snapshot: render failed\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        return SnapshotIO.write(data, to: path)
    }
}

/// Shared PNG writer for the snapshot harnesses. The app is sandboxed, so an
/// arbitrary path like /tmp fails — silently, when written with try?. Write,
/// and on denial fall back to the container's temp dir, always returning the
/// URL that actually holds the file.
enum SnapshotIO {
    static func write(_ data: Data, to path: String) -> URL {
        let requested = URL(fileURLWithPath: path)
        do {
            try data.write(to: requested)
            return requested
        } catch {
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(requested.lastPathComponent)
            do {
                try data.write(to: fallback)
                return fallback
            } catch {
                FileHandle.standardError.write(Data("snapshot: write failed — \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }
}

/// Dev-only: one real analysis pass through the selected copilot provider.
///   Parrot --analyze-test [claude|ollama|custom] [model]
/// Fixture sales transcript + the Sales discovery preset profile; prints the
/// parsed cards, sentiment, and token usage so structured-output quality of a
/// backend can be judged without a live call. Exits non-zero on failure.
enum AnalyzeTest {
    static func run(provider: String?, model: String?) {
        // register(defaults:) supplies values without persisting anything —
        // the app's real settings are untouched.
        if let provider {
            UserDefaults.standard.register(defaults: ["copilotProvider": provider])
        }
        if let model {
            UserDefaults.standard.register(defaults: [
                "copilotOllamaModel": model,
                "copilotCustomModel": model,
            ])
        }

        let profile = ProfilePresets.all().first { $0.name == "Sales discovery" }
        let transcript = """
        [00:12] Them: So walk me through how the migration from our current tool would work.
        [00:31] Me: Great question — we handle the export and import for you, usually within a week.
        [01:02] Them: Okay. And honestly the price feels steep compared to what we pay now.
        [01:18] Me: Understood — can I ask what you're comparing against?
        [01:25] Them: We pay about half of your quote today. Also, is the data stored in the EU?
        [01:40] Me: Let me get back to you on hosting regions.
        [02:05] Them: Alright. We'd want to start with the five-person sales pod if we do this.
        """
        let request = AnalysisRequest(
            transcript: transcript,
            knownInsightTitles: [],
            references: [],
            instructions: "",
            callBrief: "",
            allowGeneralKnowledge: true,
            knownDocumentNames: [],
            persona: profile?.persona ?? "You assist a sales professional during live calls.",
            counterpart: "the prospect",
            kinds: profile?.kinds ?? [],
            gauges: profile?.gauges ?? []
        )

        var exitCode: Int32 = 1
        let sem = DispatchSemaphore(value: 0)
        Task {
            let analysisProvider = SwitchingAnalysisProvider()
            let start = Date()
            do {
                let result = try await analysisProvider.analyze(request)
                let secs = String(format: "%.1f", Date().timeIntervalSince(start))
                print("=== analyze-test (\(CopilotProviderKind.selected.rawValue) · \(CopilotProviderKind.activeModelName)) — \(secs)s")
                print("coach: \(result.coach ?? "-")")
                print("score: \(result.sentiment["score"].map(String.init) ?? "MISSING") · read: \(result.read ?? "-")")
                print("gauges: \(result.sentiment.filter { $0.key != "score" })")
                for insight in result.insights {
                    var line = "- [\(insight.kindKey)] \(insight.title) — \(insight.detail)"
                    if let reply = insight.reply { line += " | say: \(reply)" }
                    if let source = insight.source { line += " | src: \(source)" }
                    print(line)
                }
                let usage = analysisProvider.usageTotals
                print("usage: \(usage.calls) call(s), \(usage.inputTokens) in / \(usage.outputTokens) out")
                // Schema honored = the always-required sentiment.score came back.
                exitCode = result.sentiment["score"] != nil ? 0 : 1
            } catch {
                print("analyze-test FAILED: \(error.localizedDescription)")
            }
            sem.signal()
        }
        sem.wait()
        exit(exitCode)
    }
}

/// Offscreen renderer for the sidebar's waveform meeting rows. Run with:
///   Parrot --sidebar-snapshot /tmp/sidebar.png
/// Seeds an in-memory store with meetings whose transcripts have distinct talk
/// balances (even, me-heavy, live-recording, empty) so the dual-lane strips can
/// be eyeballed in light AND dark ("-dark" suffix). Dev-only.
@MainActor
enum SidebarSnapshot {
    static func write(to path: String) {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
        guard let container = try? ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        ) else {
            FileHandle.standardError.write(Data("sidebar-snapshot: container failed\n".utf8))
            exit(1)
        }
        let context = container.mainContext

        // Alternating two-sided call — balanced strip.
        let balanced = seed(context, "Sales discovery — Acme", minutes: 45,
                            pattern: [("Me", 20), ("Them", 40), ("Me", 30), ("Them", 25)])
        // The user monologues the middle third — lopsided top lane.
        let meHeavy = seed(context, "1:1 coaching — Deniz", minutes: 30,
                           pattern: [("Them", 15), ("Me", 90), ("Them", 20), ("Me", 15)])
        // Live recording, few segments so the strip is sparse.
        let live = seed(context, "Weekly review", minutes: 4,
                        pattern: [("Me", 12), ("Them", 8)])
        live.status = .recording
        // No transcript at all — centerline only.
        let empty = seed(context, "Imported audio", minutes: 0, pattern: [])

        let rows = VStack(spacing: 1) {
            MeetingRow(meeting: live, selected: false)
            MeetingRow(meeting: balanced, selected: true)
            MeetingRow(meeting: meHeavy, selected: false)
            MeetingRow(meeting: empty, selected: false)
        }
        .padding(8)
        .frame(width: 240)
        .background(Theme.Colors.panel)

        let light = render(rows, dark: false, to: path)
        let dark = render(rows, dark: true, to: (path as NSString).deletingPathExtension + "-dark.png")
        FileHandle.standardError.write(Data("sidebar-snapshot: wrote \(light.path) + \(dark.path)\n".utf8))
        exit(0)
    }

    /// Repeats `pattern` (speaker, seconds) turns until the duration is filled.
    private static func seed(_ context: ModelContext, _ title: String,
                             minutes: Double, pattern: [(String, Double)]) -> Meeting {
        let meeting = Meeting(title: title)
        meeting.duration = minutes * 60
        meeting.status = .done
        context.insert(meeting)
        guard !pattern.isEmpty else { return meeting }
        var t: TimeInterval = 0
        var i = 0
        while t < meeting.duration {
            let (speaker, secs) = pattern[i % pattern.count]
            let seg = TranscriptSegment(startTime: t, endTime: min(t + secs, meeting.duration),
                                        text: "…", speakerLabel: speaker)
            seg.meeting = meeting
            context.insert(seg)
            t += secs + 4  // small silence gap between turns
            i += 1
        }
        return meeting
    }

    private static func render(_ view: some View, dark: Bool, to path: String) -> URL {
        let renderer = ImageRenderer(
            content: AnyView(view.environment(\.colorScheme, dark ? .dark : .light)))
        renderer.scale = 2
        var cg: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            cg = renderer.cgImage
        }
        guard let cg else {
            FileHandle.standardError.write(Data("sidebar-snapshot: render failed\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        return SnapshotIO.write(data, to: path)
    }
}

/// Offscreen renderer for design verification. Run with:
///   Parrot --snapshot /tmp/report.png
/// It renders the post-meeting report exactly as the app does (same views + theme)
/// to a PNG, so the SwiftUI output can be checked against the design mockup without
/// driving the GUI. Dev-only; never reached in normal launches.
@MainActor
enum ReportSnapshot {
    static func write(to path: String) {
        // A faithful slice of the report screen: title + meta + the styled
        // report content (the part that was previously a raw-text dump).
        let view = VStack(alignment: .leading, spacing: 0) {
            Text("Parenting coaching session")
                .font(Theme.Typography.title(20))
                .foregroundStyle(Theme.Colors.ink)
            HStack(spacing: 8) {
                metaPill("calendar", "Jun 19, 2026")
                metaPill("clock", "49 min")
                metaPill("person", "NHS Advisor")
            }
            .padding(.top, 12)

            Divider().overlay(Theme.Colors.line).padding(.vertical, 16)

            ReportContentView(summary: sampleSummary, coaching: sampleCoaching, talkPercentMe: 29)
        }
        .frame(width: 600, alignment: .leading)
        .padding(Theme.Metrics.pad)
        .background(Theme.Colors.canvas)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write(Data("snapshot: render failed\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        let written = SnapshotIO.write(data, to: path)
        FileHandle.standardError.write(Data("snapshot: wrote \(written.path)\n".utf8))
        exit(0)
    }

    private static func metaPill(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
    }

    static let sampleSummary = """
    # Post-Call Report

    This was a one-on-one session between a parent and a clinician focused on Alex's ADHD management — emotion recognition, a 12-minute "regulation corner", and selectively ignoring attention-seeking behaviour. The call was productive; the parent committed to several new strategies before the next session on July 10th.

    Key points:
    - Alex's week was generally positive with mild arguments; morning routine improved despite late-night World Cup watching
    - Timeout reframed as a 12-minute "regulation corner" (not punishment)
    - Parent struggles with emotion-naming; clinician modelled how to validate Alex's feelings during disappointment
    - Selective ignoring introduced for attention-seeking behaviours like monster sounds (10–15 minutes max)

    Next steps:
    - Review handouts 20–23 and create a calm-down menu with Alex
    - Practise emotion-naming in calm, positive moments first
    - Confirm online vs in-person for next week before end of workday
    """

    static let sampleCoaching = """
    Call snapshot: Parenting coaching session on managing a child's behaviour — Me spoke 29%, Them 71%. Heavy teaching call with good engagement.

    What went well:
    - Acknowledged gaps in his own skills directly and asked for examples instead of deflecting
    - Strong vulnerability at 19:15 when sharing guilt over raising his voice, which built trust
    - Took notes on handouts and committed to specific follow-ups

    What to improve:
    - Didn't fully grasp praising effort vs naming emotion — could have asked a clarifying question earlier
    - Drifted into a 3-minute tech tangent near the end when time was tight

    Commitments & follow-ups:
    - Read handouts 20, 21, 22, 23 before the next meeting
    - Create a calm-down menu and report back on which skills Alex likes
    """
}
