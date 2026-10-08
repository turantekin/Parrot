import Foundation

enum ProfilePresets {
    static let defaultProfileID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    private static let salesID    = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private static let coachingID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
    private static let interviewID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
    private static let supportID  = UUID(uuidString: "00000000-0000-0000-0000-0000000000C4")!
    private static let genericID  = UUID(uuidString: "00000000-0000-0000-0000-0000000000C5")!
    private static let vendorID   = UUID(uuidString: "00000000-0000-0000-0000-0000000000C6")!
    private static let investorID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C7")!

    /// Bump when the built-in preset definitions change (persona, kinds, counterpart).
    /// `ProfileStore` refreshes built-in profiles whose stored version is older,
    /// so existing installs pick up improvements without wiping user-owned fields.
    /// v2: "Discovery gap" relabeled "Ask this next" — users didn't know what the
    /// grey card was for.
    /// v3: "Ask this next" recolored grey → warm gold; grey read as boring for a
    /// card that carries real value (and the parrot is colorful).
    /// v4: "Vendor call" preset added — the user is the customer (a bank,
    /// supplier or agency is pitching or onboarding them). Sales discovery cast
    /// the bank as "the prospect" on a real call.
    /// v5: Profiles 2.0. Built-ins get their own report templates (see
    /// `reportTemplate(for:)`) and the "Investor pitch" preset is added.
    static let presetVersion = 5

    // The hex strings below are persisted in user data — never change them when
    // retheming the app. KindResolver.adaptiveColor maps each one to an adaptive
    // light/dark pair at render time.
    private static func kind(_ key: String, _ label: String, _ hex: String, _ icon: String,
                             _ trigger: String, pinned: Bool = false, priority: Int = 0) -> ProfileKind {
        ProfileKind(id: UUID(), key: key, label: label, colorHex: hex, iconSystemName: icon,
                    triggerDescription: trigger, isPinned: pinned, priority: priority)
    }
    private static func gauge(_ key: String, _ label: String, _ low: String, _ high: String, _ hex: String) -> SentimentGauge {
        SentimentGauge(id: UUID(), key: key, label: label, lowLabel: low, highLabel: high, colorHex: hex)
    }

    /// A fresh built-in follows its shipped report and is known across Macs
    /// by its preset id.
    private static func shipped(_ p: CallProfile) -> CallProfile {
        p.reportChoice = .preset
        p.sharedID = p.id
        p.sharedVersion = 1
        p.sharedSource = "builtin"
        return p
    }

    /// Default = today's exact behavior. persona/tone/fallback injected from migration.
    static func makeDefault(persona: String, tone: String, allowGeneralKnowledge: Bool) -> CallProfile {
        shipped(CallProfile(
            id: defaultProfileID, name: "Default", iconSystemName: "person.wave.2",
            summary: "General-purpose Assistant (your current setup).",
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
        ))
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
                    kind("discovery_gap", "Ask this next", "C29218", "magnifyingglass", "An important unknown (budget, timeline, decision maker, success criteria) the user hasn't asked about yet — phrase the title as the question to ask."),
                ],
                gauges: [gauge("buying_temperature", "Buying temp", "Cold", "Hot", "E8943A"),
                         gauge("my_dominance", "You're talking", "Balanced", "Dominating", "5F6470")]),
            CallProfile(id: coachingID, name: "1:1 coaching", iconSystemName: "heart.text.square",
                summary: "Supportive listening for coaching / 1:1s.",
                isBuiltIn: true, sortOrder: 2,
                persona: "You are a warm, non-judgmental coaching assistant. Help the user listen deeply, reflect back, and ask open questions. Never frame the other person as an objection or obstacle.",
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
                persona: "You are an interview assistant helping the user assess a candidate fairly. Surface follow-ups, signals, and red flags; help them cover the ground they planned.",
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
                persona: "You are a calm, helpful support assistant. Help the user resolve the customer's issue clearly and keep them reassured.",
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
                summary: "Minimal, neutral Assistant for any call.",
                isBuiltIn: true, sortOrder: 5,
                persona: "You are a neutral meeting assistant. Surface useful suggestions, open questions, and action items without assuming the call's purpose.",
                tone: "", counterpart: "the other person", allowGeneralKnowledge: true,
                presetVersion: presetVersion,
                kinds: [
                    kind("suggestion", "Suggestion", "4F6FB0", "lightbulb.fill", "A useful thing the user could say in response to the recent conversation."),
                    kind("question", "Open question", "2F7E96", "questionmark.circle.fill", "A direct question the other person asked that hasn't been answered."),
                    kind("action_item", "Action item", "3F9168", "checkmark.circle.fill", "Something the user committed to; include any timing."),
                    kind("note", "Note", "5F6470", "note.text", "A neutral observation worth capturing."),
                ],
                gauges: [gauge("engagement", "Engagement", "Flat", "Engaged", "2F7E96")]),
            CallProfile(id: vendorID, name: "Vendor call", iconSystemName: "building.columns",
                summary: "You are the customer: a bank, supplier or agency is pitching or onboarding you.",
                isBuiltIn: true, sortOrder: 6,
                persona: vendorPersona,
                tone: "", counterpart: "the vendor", allowGeneralKnowledge: true,
                presetVersion: presetVersion,
                kinds: [
                    kind("their_commitment", "Their commitment", "3F9168", "checkmark.seal.fill", "The vendor promised something concrete: a timeline, a feature, a fee, a follow-up, a document. Capture it exactly as said."),
                    kind("my_open_question", "My open question", "C0563B", "questionmark.bubble.fill", "You asked the vendor something and did not get a clear answer, or the vendor moved on. Flag it so you can circle back; the reply is how to ask it again.", pinned: true, priority: 10),
                    kind("red_flag", "Red flag", "E8943A", "exclamationmark.triangle.fill", "A limitation, risk, fee, hold, exclusion, lock-in or condition the vendor mentioned that could hurt you. Quote the condition.", pinned: true, priority: 9),
                    kind("pricing_detail", "Pricing detail", "4F6FB0", "tag.fill", "A number the vendor stated: fee, rate, settlement time, limit, minimum, timeline. Record it so it is not lost."),
                    kind("ask_this", "Ask this", "C29218", "magnifyingglass", "An important thing you have not asked this vendor yet: pricing, timelines, support, exit terms, compliance steps. Phrase the title as the question.", priority: 7),
                    kind("next_step", "Next step", "2F7E96", "calendar.badge.plus", "A concrete action either side agreed to; say who and when."),
                ],
                gauges: [gauge("fit", "Fit", "Poor", "Strong", "3F9168"),
                         gauge("my_dominance", "You're talking", "Balanced", "Dominating", "5F6470")]),
            CallProfile(id: investorID, name: "Investor pitch", iconSystemName: "chart.line.uptrend.xyaxis",
                summary: "Pitching to VCs and angels.",
                isBuiltIn: true, sortOrder: 7,
                persona: investorPersona,
                tone: "", counterpart: "the investor", allowGeneralKnowledge: true,
                presetVersion: presetVersion,
                kinds: [
                    kind("suggestion", "Suggested answer", "4F6FB0", "lightbulb.fill", "The investor asked something. Draft a short, confident answer the user can give now, with a number when one is known."),
                    kind("objection", "Objection", "E8943A", "hand.raised.fill", "The investor pushed back on market size, team, traction, competition or terms, and it isn't resolved.", pinned: true, priority: 10),
                    kind("unanswered_question", "Unanswered question", "C0563B", "questionmark.bubble.fill", "The investor asked a question and the conversation moved on without a real answer. Flag it so the user can come back to it.", pinned: true, priority: 9),
                    kind("interest_signal", "Interest signal", "3F9168", "arrow.up.right.circle.fill", "The investor showed interest: asked about terms, a next meeting, partners or diligence."),
                    kind("their_ask", "They asked for", "2F7E96", "tray.and.arrow.down.fill", "The investor asked for data, a deck, metrics or an intro. Capture exactly what, so it gets sent."),
                    kind("ask_this", "Ask this", "C29218", "magnifyingglass", "Something the user should learn about this investor: check size, stage, lead or follow, timeline, conflicts. Phrase the title as the question.", priority: 7),
                ],
                gauges: [gauge("interest", "Interest", "Cold", "Leaning in", "3F9168"),
                         gauge("my_dominance", "You're talking", "Balanced", "Dominating", "5F6470")]),
        ].map(shipped)
    }

    // MARK: - Report templates

    private static func section(_ key: String, _ title: String, _ type: String, _ guide: String,
                                commitments: Bool = false) -> ReportTemplate.Section {
        ReportTemplate.Section(key: key, title: title, type: type, guide: guide,
                               commitments: commitments ? true : nil)
    }

    private static func scorecard(_ key: String, _ title: String, _ guide: String,
                                  _ criteria: [(String, String, String)]) -> ReportTemplate.Section {
        ReportTemplate.Section(key: key, title: title, type: "scorecard", guide: guide,
                               criteria: criteria.map { .init(key: $0.0, label: $0.1, guide: $0.2) })
    }

    private static func coach(_ role: String, _ focus: String) -> ReportTemplate.Coaching {
        ReportTemplate.Coaching(enabled: true, role: role, focus: focus)
    }

    /// The report each built-in ships with. Default and Generic keep the
    /// standard report. Kept short on purpose: every template here was
    /// checked on the default local model (see `--analyze-test` report mode).
    static let reportTemplates: [UUID: ReportTemplate] = [
        defaultProfileID: .standard,
        genericID: .standard,
        salesID: ReportTemplate(sections: [
            section("overview", "Overview", "prose", "2-3 sentences: what the call was about and where the deal stands."),
            section("pain", "Pain points", "bullets", "What the prospect is struggling with and why it matters to them."),
            section("budget", "Budget", "bullets", "What they said about budget, price or what they spend today."),
            section("decision", "Decision-maker", "bullets", "Who decides, who else is involved, and how they buy."),
            section("timeline", "Timeline", "bullets", "When they want to decide or start, and why then."),
            section("objections", "Objections", "bullets", "Concerns they raised, and whether each one was answered."),
            section("next", "Next steps", "bullets", "What someone said they'd do, with any date.", commitments: true),
        ], coaching: coach("sales coach", "Discovery: pain, budget, decision-maker and timeline. How objections were handled.")),
        interviewID: ReportTemplate(sections: [
            section("overview", "Overview", "prose", "2-3 sentences: the role, how the conversation went, and anything decided."),
            scorecard("scorecard", "Scorecard", "Only what the candidate said on this call.", [
                ("experience", "Relevant experience", "Has done similar work, with real examples"),
                ("problems", "Problem solving", "How they work through a problem"),
                ("communication", "Communication", "Explains clearly and answers the question asked"),
                ("teamwork", "Teamwork", "How they work with others and handle disagreement"),
            ]),
            section("strengths", "Strengths", "bullets", "Things the candidate showed they can do, with the moment it came up."),
            section("concerns", "Concerns", "bullets", "Gaps or doubts from what the candidate said. Only job-related points, never age, looks, accent or other personal traits."),
            section("uncovered", "Still to cover", "bullets", "Planned topics or questions that didn't come up."),
            section("next", "Next steps", "bullets", "What someone said they'd do, with any date.", commitments: true),
        ], coaching: coach("interview coach", "Question quality, fairness, and giving the candidate room to talk.")),
        supportID: ReportTemplate(sections: [
            section("issue", "Issue", "prose", "1-2 sentences: what the customer needed help with."),
            section("cause", "Cause", "bullets", "What caused the problem, if it came up."),
            section("resolved", "Resolved", "bullets", "What was fixed or answered on the call."),
            section("followups", "Follow-ups", "bullets", "What someone promised to do after the call, with any date.", commitments: true),
            section("mood", "Mood", "prose", "One line: how the customer felt at the start and at the end."),
        ], coaching: coach("support coach", "Clarity, empathy, and whether the issue was really solved.")),
        coachingID: ReportTemplate(sections: [
            // Starts with a paragraph like the others: bullets-only came back
            // ragged on gemma3:4b ("Wins - …", no colons) in two runs.
            section("overview", "Overview", "prose", "1-2 sentences: how the person is doing and what you talked about."),
            section("wins", "Wins", "bullets", "Progress or good news the person shared."),
            section("blockers", "Blockers", "bullets", "What is in their way or worrying them."),
            section("commitments", "Commitments", "bullets", "What either of you said you'd do, with any date.", commitments: true),
        ], coaching: ReportTemplate.Coaching(enabled: false, role: nil, focus: nil)),
        vendorID: ReportTemplate(sections: [
            section("offer", "Offer", "prose", "2-3 sentences: what the vendor offered and how the call ended."),
            section("pricing", "Pricing and terms", "bullets", "Every fee, rate, limit and timeline the vendor stated, word for word."),
            section("redflags", "Red flags", "bullets", "Risks, holds, exclusions, lock-in or conditions that could hurt you."),
            section("open", "Open questions", "bullets", "What you asked that wasn't answered clearly."),
            section("commitments", "Commitments", "bullets", "What either side said they'd do or send, with any date.", commitments: true),
        ], coaching: coach("negotiation coach", "Getting clear answers, firm numbers and promises in writing.")),
        investorID: ReportTemplate(sections: [
            section("overview", "Overview", "prose", "2-3 sentences: what the call was about and how it ended."),
            section("liked", "What they liked", "bullets", "Parts of the pitch the investor responded well to."),
            section("concerns", "Their concerns", "bullets", "Doubts about market, team, traction or terms."),
            section("asks", "What they asked for", "bullets", "Data, metrics or intros they requested."),
            scorecard("fit", "Fit", "How well this investor fits the round.", [
                ("stage", "Stage fit", "Do they invest at our stage?"),
                ("check", "Check size", "Does their usual check match the round?"),
            ]),
            section("next", "Next steps", "bullets", "What someone said they'd do, with any date.", commitments: true),
        ], coaching: coach("pitch coach", "Clarity of the story, handling tough questions, the ask.")),
    ]

    /// The built-in reports a profile can start from, by profile name.
    static let reportStarters: [(name: String, template: ReportTemplate)] =
        all().filter { !$0.reportTemplate.isStandard }.map { ($0.name, $0.reportTemplate) }

    /// A built-in's shipped report, nil for anything that isn't a built-in.
    static func reportTemplate(for id: UUID) -> ReportTemplate? { reportTemplates[id] }

    /// The framing scaffold the Default profile uses (mirrors today's hardcoded prompt intent).
    private static let defaultPersona = "You are a live call assistant. Draft short, concrete lines the user can say, flag obstacles, and capture commitments."

    /// Vendor call persona — the user is buying, and the copilot protects their side.
    private static let vendorPersona = """
    You assist someone who is the CUSTOMER on this call: a bank, payment provider, supplier or agency \
    is explaining what it offers, answering their questions, or onboarding them. The user is not \
    selling anything and the other party is never a prospect. Protect the user's interests: capture \
    exactly what the vendor commits to and what it costs, flag risks, holds, exclusions and unanswered \
    questions, and suggest what to ask next. Keep the vendor's numbers verbatim.
    """

    /// Investor pitch persona — the user is the founder asking for money.
    private static let investorPersona = """
    You are coaching a founder pitching to an investor (a VC or angel) on a live call. Help the \
    founder answer crisply with numbers, handle pushback without getting defensive, notice what the \
    investor cares about, and make sure the call ends with a clear next step. Every card must be \
    usable in the next 30 seconds.
    """

    /// Sales discovery persona — a real-time coach, not just a suggestion engine.
    private static let salesPersona = """
    You are an elite B2B sales coach embedded in a live discovery call, coaching the user in real time. \
    Push qualification over pitching: help the user uncover pain, budget, authority, and timeline. \
    Don't just hand over lines — coach. Call it out when the user is talking too much, skips a buying \
    signal, leaves the prospect's question unanswered, or misses a chance to dig into a stated pain. \
    Every card must be usable in the next 30 seconds.
    """
}
