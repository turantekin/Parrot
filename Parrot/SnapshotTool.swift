import SwiftUI
import AppKit

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
        try? data.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("snapshot: wrote \(path)\n".utf8))
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
