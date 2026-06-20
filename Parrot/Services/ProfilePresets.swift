import Foundation

enum ProfilePresets {
    static let defaultProfileID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    private static let salesID    = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private static let coachingID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
    private static let interviewID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
    private static let supportID  = UUID(uuidString: "00000000-0000-0000-0000-0000000000C4")!
    private static let genericID  = UUID(uuidString: "00000000-0000-0000-0000-0000000000C5")!

    private static func kind(_ key: String, _ label: String, _ hex: String, _ icon: String,
                             _ trigger: String, pinned: Bool = false, priority: Int = 0) -> ProfileKind {
        ProfileKind(id: UUID(), key: key, label: label, colorHex: hex, iconSystemName: icon,
                    triggerDescription: trigger, isPinned: pinned, priority: priority)
    }
    private static func gauge(_ key: String, _ label: String, _ low: String, _ high: String, _ hex: String) -> SentimentGauge {
        SentimentGauge(id: UUID(), key: key, label: label, lowLabel: low, highLabel: high, colorHex: hex)
    }

    /// Default = today's exact behavior. persona/tone/fallback injected from migration.
    static func makeDefault(persona: String, tone: String, allowGeneralKnowledge: Bool) -> CallProfile {
        CallProfile(
            id: defaultProfileID, name: "Default", iconSystemName: "person.wave.2",
            summary: "General-purpose copilot (your current setup).",
            isBuiltIn: true, sortOrder: 0, persona: persona, tone: tone,
            allowGeneralKnowledge: allowGeneralKnowledge,
            kinds: [
                kind("suggestion", "Suggested answer", "4F6FB0", "lightbulb.fill", "Them asked something or raised a topic — draft a short, concrete answer Me can say now."),
                kind("question", "Open question", "2F7E96", "questionmark.circle.fill", "Them asked a direct question Me has NOT answered yet — surface it briefly."),
                kind("blocker", "Blocker", "E8943A", "exclamationmark.triangle.fill", "Them raised an objection or obstacle (price, timing, decision maker, competitor) Me hasn't resolved.", pinned: true, priority: 10),
                kind("action_item", "Action item", "3F9168", "checkmark.circle.fill", "Me committed to do something after the call; include any time/date mentioned."),
                kind("feedback", "Feedback", "5F6470", "chart.line.uptrend.xyaxis", "A brief read on a SIGNIFICANT shift only — sparingly."),
            ],
            gauges: [gauge("my_dominance", "You're talking", "Balanced", "Dominating", "5F6470")]
        )
    }

    static func all() -> [CallProfile] {
        [
            makeDefault(persona: defaultPersona, tone: "", allowGeneralKnowledge: true),
            CallProfile(id: salesID, name: "Sales discovery", iconSystemName: "dollarsign.circle",
                summary: "Discovery & objection handling for sales calls.",
                isBuiltIn: true, sortOrder: 1,
                persona: "You are a sharp B2B sales copilot helping Me run a discovery call. Favor curiosity and qualification over pitching; help Me uncover pain, budget, and decision process.",
                tone: "", allowGeneralKnowledge: true,
                kinds: [
                    kind("suggestion", "Suggested answer", "4F6FB0", "lightbulb.fill", "Them asked something — draft a short concrete answer Me can say now."),
                    kind("objection", "Objection", "E8943A", "hand.raised.fill", "Them raised a concern (price, timing, competitor, authority) Me hasn't resolved.", pinned: true, priority: 10),
                    kind("buying_signal", "Buying signal", "3F9168", "arrow.up.right.circle.fill", "Them showed interest or intent — note it so Me can advance."),
                    kind("next_step", "Next step", "2F7E96", "calendar.badge.plus", "A concrete next step or commitment to propose or confirm."),
                    kind("discovery_gap", "Discovery gap", "5F6470", "magnifyingglass", "An important unknown (budget, timeline, decision maker) Me hasn't asked about."),
                ],
                gauges: [gauge("buying_temperature", "Buying temp", "Cold", "Hot", "E8943A"),
                         gauge("my_dominance", "You're talking", "Balanced", "Dominating", "5F6470")]),
            CallProfile(id: coachingID, name: "1:1 coaching", iconSystemName: "heart.text.square",
                summary: "Supportive listening for coaching / 1:1s.",
                isBuiltIn: true, sortOrder: 2,
                persona: "You are a warm, non-judgmental coaching copilot. Help Me listen deeply, reflect back, and ask open questions. Never frame the other person as an objection or obstacle.",
                tone: "", allowGeneralKnowledge: true,
                kinds: [
                    kind("reflection", "Reflection", "4F6FB0", "quote.bubble.fill", "Offer a brief reflective statement Me could mirror back to show understanding."),
                    kind("open_question", "Open question", "2F7E96", "questionmark.circle.fill", "A non-leading open question Me could ask to deepen the conversation."),
                    kind("emotional_cue", "Emotional cue", "E8943A", "waveform.path.ecg", "Them expressed a notable emotion (frustration, relief, worry) worth acknowledging.", pinned: false, priority: 5),
                    kind("commitment", "Commitment", "3F9168", "checkmark.circle.fill", "Either side committed to a concrete next step; include any timing."),
                    kind("coaching_moment", "Coaching moment", "5F6470", "lightbulb.fill", "An opening for Me to offer guidance or a useful reframe."),
                ],
                gauges: [gauge("client_openness", "Openness", "Guarded", "Open", "2F7E96"),
                         gauge("my_dominance", "You're talking", "Balanced", "Dominating", "5F6470")]),
            CallProfile(id: interviewID, name: "Interview", iconSystemName: "person.crop.rectangle.stack",
                summary: "For when you're interviewing a candidate.",
                isBuiltIn: true, sortOrder: 3,
                persona: "You are an interview copilot helping Me assess a candidate fairly. Surface follow-ups, signals, and red flags; help Me cover the ground I planned.",
                tone: "", allowGeneralKnowledge: true,
                kinds: [
                    kind("follow_up_question", "Follow-up", "2F7E96", "questionmark.circle.fill", "A sharp follow-up question to probe the candidate's last answer."),
                    kind("red_flag", "Red flag", "E8943A", "flag.fill", "Something concerning in the candidate's answer worth noting.", pinned: true, priority: 10),
                    kind("strong_signal", "Strong signal", "3F9168", "star.fill", "A strong positive signal worth recording."),
                    kind("topic_to_cover", "Topic to cover", "4F6FB0", "list.bullet", "A planned topic Me hasn't covered yet."),
                    kind("note", "Note", "5F6470", "note.text", "A neutral observation worth capturing."),
                ],
                gauges: [gauge("candidate_confidence", "Confidence", "Hesitant", "Confident", "3F9168")]),
            CallProfile(id: supportID, name: "Customer support", iconSystemName: "lifepreserver",
                summary: "Resolve issues and keep customers calm.",
                isBuiltIn: true, sortOrder: 4,
                persona: "You are a calm, helpful support copilot. Help Me resolve the customer's issue clearly and keep them reassured.",
                tone: "", allowGeneralKnowledge: true,
                kinds: [
                    kind("answer", "Answer", "4F6FB0", "lightbulb.fill", "Them asked something — draft a clear, accurate answer Me can give."),
                    kind("unresolved_issue", "Unresolved issue", "E8943A", "exclamationmark.triangle.fill", "An issue Them raised that Me hasn't resolved.", pinned: true, priority: 10),
                    kind("frustration_cue", "Frustration cue", "E8943A", "waveform.path.ecg", "Them is getting frustrated — note it so Me can de-escalate."),
                    kind("follow_up", "Follow-up", "3F9168", "arrow.uturn.right", "A follow-up action Me should take or promise."),
                    kind("note", "Note", "5F6470", "note.text", "A neutral observation worth capturing."),
                ],
                gauges: [gauge("customer_frustration", "Frustration", "Calm", "Upset", "E8943A")]),
            CallProfile(id: genericID, name: "Generic", iconSystemName: "bubble.left.and.bubble.right",
                summary: "Minimal, neutral copilot for any call.",
                isBuiltIn: true, sortOrder: 5,
                persona: "You are a neutral meeting copilot. Surface useful suggestions, open questions, and action items without assuming the call's purpose.",
                tone: "", allowGeneralKnowledge: true,
                kinds: [
                    kind("suggestion", "Suggestion", "4F6FB0", "lightbulb.fill", "A useful thing Me could say in response to the recent conversation."),
                    kind("question", "Open question", "2F7E96", "questionmark.circle.fill", "A direct question Them asked that Me hasn't answered."),
                    kind("action_item", "Action item", "3F9168", "checkmark.circle.fill", "Something Me committed to; include any timing."),
                    kind("note", "Note", "5F6470", "note.text", "A neutral observation worth capturing."),
                ],
                gauges: [gauge("engagement", "Engagement", "Flat", "Engaged", "2F7E96")]),
        ]
    }

    /// The framing scaffold the Default profile uses (mirrors today's hardcoded prompt intent).
    private static let defaultPersona = "You are a live call copilot helping Me on a call. Draft short, concrete things Me can say, flag obstacles, and capture commitments."
}
