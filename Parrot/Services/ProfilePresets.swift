import Foundation

enum ProfilePresets {
    static let defaultProfileID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    private static let salesID    = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private static let coachingID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
    private static let interviewID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
    private static let supportID  = UUID(uuidString: "00000000-0000-0000-0000-0000000000C4")!
    private static let genericID  = UUID(uuidString: "00000000-0000-0000-0000-0000000000C5")!

    /// Bump when the built-in preset definitions change (persona, kinds, counterpart).
    /// `ProfileStore` refreshes built-in profiles whose stored version is older,
    /// so existing installs pick up improvements without wiping user-owned fields.
    static let presetVersion = 1

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
            counterpart: "the other person",
            allowGeneralKnowledge: allowGeneralKnowledge, presetVersion: presetVersion,
            kinds: [
                kind("suggestion", "Suggested answer", "4F6FB0", "lightbulb.fill", "The other person asked something or raised a topic — draft a short, concrete line to say now."),
                kind("question", "Open question", "2F7E96", "questionmark.circle.fill", "The other person asked a direct question that has NOT been answered yet — surface it briefly."),
                kind("blocker", "Blocker", "E8943A", "exclamationmark.triangle.fill", "An objection or obstacle came up (price, timing, decision maker, competitor) that isn't resolved.", pinned: true, priority: 10),
                kind("action_item", "Action item", "3F9168", "checkmark.circle.fill", "The user committed to do something after the call; include any time/date mentioned."),
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
                persona: salesPersona,
                tone: "", counterpart: "the prospect", allowGeneralKnowledge: true,
                presetVersion: presetVersion,
                kinds: [
                    kind("suggestion", "Suggested answer", "4F6FB0", "lightbulb.fill", "The prospect asked something — draft a short, concrete line to say now."),
                    kind("objection", "Objection", "E8943A", "hand.raised.fill", "The prospect raised a concern (price, timing, competitor, authority) that isn't resolved.", pinned: true, priority: 10),
                    kind("unanswered_question", "Unanswered question", "C0563B", "questionmark.bubble.fill", "The prospect asked a question and the conversation moved on WITHOUT actually answering it — flag it so the user can circle back.", pinned: true, priority: 9),
                    kind("opportunity", "Opportunity", "7A5FB0", "sparkles", "The prospect revealed a pain, goal, or need the user's offering could solve — suggest how to position a solution (ground it in the knowledge base when available).", priority: 7),
                    kind("buying_signal", "Buying signal", "3F9168", "arrow.up.right.circle.fill", "The prospect showed interest or intent — flag it so the user can advance the deal."),
                    kind("next_step", "Next step", "2F7E96", "calendar.badge.plus", "A concrete next step or commitment to propose or confirm."),
                    kind("discovery_gap", "Discovery gap", "5F6470", "magnifyingglass", "An important unknown (budget, timeline, decision maker, success criteria) the user hasn't asked about yet."),
                ],
                gauges: [gauge("buying_temperature", "Buying temp", "Cold", "Hot", "E8943A"),
                         gauge("my_dominance", "You're talking", "Balanced", "Dominating", "5F6470")]),
            CallProfile(id: coachingID, name: "1:1 coaching", iconSystemName: "heart.text.square",
                summary: "Supportive listening for coaching / 1:1s.",
                isBuiltIn: true, sortOrder: 2,
                persona: "You are a warm, non-judgmental coaching copilot. Help the user listen deeply, reflect back, and ask open questions. Never frame the other person as an objection or obstacle.",
                tone: "", counterpart: "the person", allowGeneralKnowledge: true,
                presetVersion: presetVersion,
                kinds: [
                    kind("reflection", "Reflection", "4F6FB0", "quote.bubble.fill", "Offer a brief reflective statement the user could mirror back to show understanding."),
                    kind("open_question", "Open question", "2F7E96", "questionmark.circle.fill", "A non-leading open question the user could ask to deepen the conversation."),
                    kind("emotional_cue", "Emotional cue", "E8943A", "waveform.path.ecg", "The person expressed a notable emotion (frustration, relief, worry) worth acknowledging.", pinned: false, priority: 5),
                    kind("commitment", "Commitment", "3F9168", "checkmark.circle.fill", "Either side committed to a concrete next step; include any timing."),
                    kind("coaching_moment", "Coaching moment", "5F6470", "lightbulb.fill", "An opening for the user to offer guidance or a useful reframe."),
                ],
                gauges: [gauge("client_openness", "Openness", "Guarded", "Open", "2F7E96"),
                         gauge("my_dominance", "You're talking", "Balanced", "Dominating", "5F6470")]),
            CallProfile(id: interviewID, name: "Interview", iconSystemName: "person.crop.rectangle.stack",
                summary: "For when you're interviewing a candidate.",
                isBuiltIn: true, sortOrder: 3,
                persona: "You are an interview copilot helping the user assess a candidate fairly. Surface follow-ups, signals, and red flags; help them cover the ground they planned.",
                tone: "", counterpart: "the candidate", allowGeneralKnowledge: true,
                presetVersion: presetVersion,
                kinds: [
                    kind("follow_up_question", "Follow-up", "2F7E96", "questionmark.circle.fill", "A sharp follow-up question to probe the candidate's last answer."),
                    kind("red_flag", "Red flag", "E8943A", "flag.fill", "Something concerning in the candidate's answer worth noting.", pinned: true, priority: 10),
                    kind("strong_signal", "Strong signal", "3F9168", "star.fill", "A strong positive signal worth recording."),
                    kind("topic_to_cover", "Topic to cover", "4F6FB0", "list.bullet", "A planned topic the user hasn't covered yet."),
                    kind("note", "Note", "5F6470", "note.text", "A neutral observation worth capturing."),
                ],
                gauges: [gauge("candidate_confidence", "Confidence", "Hesitant", "Confident", "3F9168")]),
            CallProfile(id: supportID, name: "Customer support", iconSystemName: "lifepreserver",
                summary: "Resolve issues and keep customers calm.",
                isBuiltIn: true, sortOrder: 4,
                persona: "You are a calm, helpful support copilot. Help the user resolve the customer's issue clearly and keep them reassured.",
                tone: "", counterpart: "the customer", allowGeneralKnowledge: true,
                presetVersion: presetVersion,
                kinds: [
                    kind("answer", "Answer", "4F6FB0", "lightbulb.fill", "The customer asked something — draft a clear, accurate answer the user can give."),
                    kind("unresolved_issue", "Unresolved issue", "E8943A", "exclamationmark.triangle.fill", "An issue the customer raised that isn't resolved yet.", pinned: true, priority: 10),
                    kind("frustration_cue", "Frustration cue", "E8943A", "waveform.path.ecg", "The customer is getting frustrated — flag it so the user can de-escalate."),
                    kind("follow_up", "Follow-up", "3F9168", "arrow.uturn.right", "A follow-up action the user should take or promise."),
                    kind("note", "Note", "5F6470", "note.text", "A neutral observation worth capturing."),
                ],
                gauges: [gauge("customer_frustration", "Frustration", "Calm", "Upset", "E8943A")]),
            CallProfile(id: genericID, name: "Generic", iconSystemName: "bubble.left.and.bubble.right",
                summary: "Minimal, neutral copilot for any call.",
                isBuiltIn: true, sortOrder: 5,
                persona: "You are a neutral meeting copilot. Surface useful suggestions, open questions, and action items without assuming the call's purpose.",
                tone: "", counterpart: "the other person", allowGeneralKnowledge: true,
                presetVersion: presetVersion,
                kinds: [
                    kind("suggestion", "Suggestion", "4F6FB0", "lightbulb.fill", "A useful thing the user could say in response to the recent conversation."),
                    kind("question", "Open question", "2F7E96", "questionmark.circle.fill", "A direct question the other person asked that hasn't been answered."),
                    kind("action_item", "Action item", "3F9168", "checkmark.circle.fill", "Something the user committed to; include any timing."),
                    kind("note", "Note", "5F6470", "note.text", "A neutral observation worth capturing."),
                ],
                gauges: [gauge("engagement", "Engagement", "Flat", "Engaged", "2F7E96")]),
        ]
    }

    /// The framing scaffold the Default profile uses (mirrors today's hardcoded prompt intent).
    private static let defaultPersona = "You are a live call copilot. Draft short, concrete lines the user can say, flag obstacles, and capture commitments."

    /// Sales discovery persona — a real-time coach, not just a suggestion engine.
    private static let salesPersona = """
    You are an elite B2B sales coach embedded in a live discovery call, coaching the user in real time. \
    Push qualification over pitching: help the user uncover pain, budget, authority, and timeline. \
    Don't just hand over lines — coach. Call it out when the user is talking too much, skips a buying \
    signal, leaves the prospect's question unanswered, or misses a chance to dig into a stated pain. \
    Every card must be usable in the next 30 seconds.
    """
}
