import SwiftUI

/// Shows what Copilot does before anyone chooses how it runs: a short
/// looping example call built from the real card views, and four benefits.
struct MeetCopilotStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 listening, 1 question heard, 2 answer card, 3 blocker pinned, 4 hold.
    @State private var phase = 0

    /// Reduce Motion, and the help-shot harness, get the finished frame.
    private var stillFrame: Bool {
        reduceMotion || UserDefaults.standard.bool(forKey: "onboardingStillFrame")
    }

    var body: some View {
        VStack(spacing: 18) {
            StepHeader(title: "Meet Copilot",
                       subtitle: "Your helper during calls. It listens and shows you what to say, as it happens.")
            HStack(alignment: .top, spacing: 18) {
                demo
                    .frame(width: 260)
                VStack(alignment: .leading, spacing: 14) {
                    benefit("lightbulb", "Know what to say", "Answers pop up when they ask, from your own documents.")
                    benefit("exclamationmark.triangle", "Catch deal-breakers", "Blockers stay pinned until you handle them.")
                    benefit("gauge.with.needle", "See how it's going", "A live score and one line of coaching.")
                    benefit("doc.text", "Leave with a report", "Summary, action items and a follow-up email.")
                }
            }
            Label("Only you see it. No bot joins your call.", systemImage: "eye.slash")
                .font(Theme.Typography.secondary)
                .padding(.vertical, Theme.Metrics.bannerInsetV)
                .frame(maxWidth: .infinity)
                .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        }
        .padding(Theme.Metrics.pad)
        .task {
            if stillFrame {
                phase = 3
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { phase = (phase + 1) % 5 }
            }
        }
    }

    private var demo: some View {
        let shown = min(phase, 3)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.Colors.accent)
                Text("Copilot")
                    .font(Theme.Typography.cardTitle)
                Spacer(minLength: 0)
                Text("Listening")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            Text(shown >= 1 ? "Them: “Where is our data stored? Security will ask.”" : "Listening to the call…")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if shown >= 2 {
                HeroInsightCard(insight: Self.answer, kindStyle: KindResolver.fallbackStyle(forKey: "suggestion"),
                                isGlowing: false, onJump: {}, onDismiss: {})
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if shown >= 3 {
                InsightCard(insight: Self.blocker, kindStyle: KindResolver.fallbackStyle(forKey: "blocker"),
                            isCollapsed: false, onToggleCollapse: {}, onJump: {}, onDismiss: {})
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Metrics.popoverPad)
        .frame(height: 340, alignment: .top)
        .clipped()
        .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: they ask where data is stored, Copilot suggests an answer from your security document, then pins a budget blocker.")
    }

    private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.appTitle3)
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.cardTitle)
                Text(detail)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static let answer = Insight(
        kindKey: "suggestion", title: "Answer the security question",
        detail: "All audio stays on your Mac. Only the text goes to the AI, and we can sign a DPA this week.",
        callTime: 754, source: "security-faq.pdf")
    static let blocker = Insight(
        kindKey: "blocker", title: "Budget isn't approved until Q3",
        detail: "They can't sign before the new budget. Ask who signs off and when.",
        callTime: 812, source: "Them")
}
