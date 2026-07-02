import SwiftUI
import AppKit
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
                    callTime: 512, source: nil),
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

        FileHandle.standardError.write(Data("copilot-snapshot: wrote \(light.path) + \(dark.path) + \(rows.path)\n".utf8))
        exit(0)
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

/// Offscreen renderer for design verification. Run with:
///   Parrot --snapshot /tmp/report.png
/// It renders the post-meeting report exactly as the app does (same views + theme)
/// to a PNG, so the SwiftUI output can be checked against the design mockup without
/// driving the GUI. Dev-only; never reached in normal launches.
@MainActor
enum ReportSnapshot {
    static func write(to path: String) {
        // A faithful slice of the report screen: serif title + meta + the styled
        // report content (the part that was previously a raw-text dump).
        let view = VStack(alignment: .leading, spacing: 0) {
            Text("Parenting coaching session")
                .font(Theme.Typography.title(27))
                .foregroundStyle(Theme.Colors.ink)
            HStack(spacing: 8) {
                metaPill("calendar", "Jun 19, 2026")
                metaPill("clock", "49 min")
                metaPill("person", "NHS Advisor")
            }
            .padding(.top, 12)

            Divider().overlay(Theme.Colors.line).padding(.vertical, 18)

            ReportContentView(summary: sampleSummary, coaching: sampleCoaching, talkPercentMe: 29)
        }
        .frame(width: 600, alignment: .leading)
        .padding(28)
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
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: 7))
    }

    static let sampleSummary = """
    # Post-Call Report

    This was a one-on-one session between a parent and a clinician focused on Jeremy's ADHD management — emotion recognition, a 12-minute "regulation corner", and selectively ignoring attention-seeking behaviour. The call was productive; the parent committed to several new strategies before the next session on July 10th.

    Key points:
    - Jeremy's week was generally positive with mild arguments; morning routine improved despite late-night World Cup watching
    - Timeout reframed as a 12-minute "regulation corner" (not punishment)
    - Parent struggles with emotion-naming; clinician modelled how to validate Jeremy's feelings during disappointment
    - Selective ignoring introduced for attention-seeking behaviours like monster sounds (10–15 minutes max)

    Next steps:
    - Review handouts 20–23 and create a calm-down menu with Jeremy
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
    - Create a calm-down menu and report back on which skills Jeremy likes
    """
}
