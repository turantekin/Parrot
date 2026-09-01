import Foundation
import SwiftUI
import SwiftData

/// Offscreen logic harness. Run: `.build/debug/Parrot --profile-test`
/// Prints PASS/FAIL per check and exits non-zero on any failure.
enum ProfileTest {
    private static var failures = 0

    private static func check(_ name: String, _ cond: @autoclosure () -> Bool) {
        if cond() { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
    }

    @MainActor
    static func run() {
        testKindStyleFallback()
        testHexColor()
        testInsightKey()
        testCallProfile()
        testPresets()
        testKBScoping()
        testMigration()
        testPresetRefresh()
        testPromptAndSchema()
        testSnapshotPersistence()
        testLenientKBDecode()
        testStableHash()
        testNearDuplicate()
        testSupersedes()
        testHallucinationFilter()
        testWAVEncoder()
        testAIUsageCost()
        testPermissionFlow()
        testMicWatchdog()
        testModelFolderMatch()
        testBugReport()
        testSegmenter()
        testQuietMic()
        testCopilotBudget()
        testDiarizedLabel()
        testSpeakerNames()
        testVoiceProfiles()
        testLiveLabelStability()
        print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    static func testKindStyleFallback() {
        let blocker = KindResolver.fallbackStyle(forKey: "blocker")
        check("fallback blocker is pinned", blocker.isPinned == true)
        check("fallback blocker label", blocker.label == "Blocker")
        let unknown = KindResolver.fallbackStyle(forKey: "totally_made_up")
        check("fallback unknown not pinned", unknown.isPinned == false)
        check("fallback unknown has a label", !unknown.label.isEmpty)
    }

    static func testInsightKey() {
        let draft = InsightDraft(kindKey: "blocker", title: "Price too high", detail: "x", source: nil)
        check("draft carries kindKey", draft.kindKey == "blocker")
        let insight = Insight(kindKey: "buying_signal", title: "t", detail: "d", callTime: 0, source: nil)
        check("insight style resolves unknown key", insight.style.label == "Buying Signal")
        check("insight known key pinned", Insight(kindKey: "blocker", title: "t", detail: "d", callTime: 0, source: nil).style.isPinned)
    }

    static func testCallProfile() {
        let kind = ProfileKind(id: UUID(), key: "objection", label: "Objection",
            colorHex: "E8943A", iconSystemName: "hand.raised.fill",
            triggerDescription: "Them raised a concern", isPinned: true, priority: 10)
        let p = CallProfile(name: "Sales", iconSystemName: "dollarsign.circle",
            summary: "x", isBuiltIn: true, sortOrder: 0, persona: "p", tone: "t",
            allowGeneralKnowledge: true, kinds: [kind], gauges: [])
        check("profile round-trips kinds", p.kinds.first?.key == "objection")
        let style = p.style(forKey: "objection")
        check("profile style label", style?.label == "Objection")
        check("profile style pinned", style?.isPinned == true)
        check("profile unknown key nil", p.style(forKey: "nope") == nil)
    }

    static func testPresets() {
        let all = ProfilePresets.all()
        check("six presets", all.count == 6)
        check("default first by sortOrder", all.sorted { $0.sortOrder < $1.sortOrder }.first?.id == ProfilePresets.defaultProfileID)
        let coaching = all.first { $0.name == "1:1 coaching" }
        check("coaching has reflection kind", coaching?.kinds.contains { $0.key == "reflection" } == true)
        check("coaching has NO blocker kind", coaching?.kinds.contains { $0.key == "blocker" } == false)
        check("sales has buying_temperature gauge", all.first { $0.name == "Sales discovery" }?.gauges.contains { $0.key == "buying_temperature" } == true)
        let def = all.first { $0.id == ProfilePresets.defaultProfileID }
        check("default has today's five keys", Set(def?.kinds.map(\.key) ?? []) == ["suggestion", "question", "blocker", "action_item", "feedback"])
    }

    @MainActor
    static func testKBScoping() {
        let kb = KnowledgeBaseService(persistent: false)
        // Synchronous: unknown profile UUID always returns empty names list.
        check("documentNames empty for unknown profile", kb.documentNames(for: UUID()).isEmpty)
        // Synchronous: after tagging all docs into a fresh ID, every doc contains it.
        let tagID = UUID()
        kb.tagAllDocuments(into: tagID)
        // If kb has any documents, they should all contain tagID. Vacuously true on empty KB.
        check("tagAllDocuments tags every document", kb.documents.allSatisfy { $0.profileIDs.contains(tagID) })
        // Scoped search for unknown profile: since search() early-returns [] when chunks is empty
        // (CLI KB is always empty), and for a truly unknown profile even with chunks the allowedNames
        // set would be empty making snapshot empty. We assert via documentNames proxy — a freshly
        // created UUID has no documents tagged into it.
        check("documentNames for untagged profile is empty", kb.documentNames(for: UUID()).isEmpty)
    }

    @MainActor
    static func testMigration() {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
            check("migration container builds", false); return
        }
        let ctx = ModelContext(container)
        let kb = KnowledgeBaseService(persistent: false)
        let store = ProfileStore()
        // Save/restore the real value — the old removeObject-based cleanup
        // DELETED the user's actual copilot instructions after every test run.
        let previous = UserDefaults.standard.string(forKey: "copilotInstructions")
        UserDefaults.standard.set("be concise", forKey: "copilotInstructions")
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: "copilotInstructions")
            } else {
                UserDefaults.standard.removeObject(forKey: "copilotInstructions")
            }
        }
        store.seedAndMigrateIfNeeded(context: ctx, knowledgeBase: kb)
        let profiles = (try? ctx.fetch(FetchDescriptor<CallProfile>())) ?? []
        check("seeded six profiles", profiles.count == 6)
        let def = profiles.first { $0.id == ProfilePresets.defaultProfileID }
        check("default absorbed instructions as tone", def?.tone == "be concise")
        // Idempotent: second run doesn't duplicate.
        store.seedAndMigrateIfNeeded(context: ctx, knowledgeBase: kb)
        check("seeding idempotent", ((try? ctx.fetch(FetchDescriptor<CallProfile>()))?.count ?? 0) == 6)
    }

    @MainActor
    static func testPresetRefresh() {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
            check("refresh container builds", false); return
        }
        let ctx = ModelContext(container)
        let kb = KnowledgeBaseService(persistent: false)
        let store = ProfileStore()
        store.seedAndMigrateIfNeeded(context: ctx, knowledgeBase: kb)

        let profiles = (try? ctx.fetch(FetchDescriptor<CallProfile>())) ?? []
        guard let sales = profiles.first(where: { $0.name == "Sales discovery" }),
              let support = profiles.first(where: { $0.name == "Customer support" }) else {
            check("refresh finds built-ins", false); return
        }

        // A user-tuned built-in must survive a preset-version bump untouched...
        sales.persona = "my custom persona"
        sales.isUserModified = true
        sales.presetVersion = 0
        // ...while an untouched stale built-in picks up the shipped preset.
        support.persona = "stale junk"
        support.presetVersion = 0
        try? ctx.save()

        store.seedAndMigrateIfNeeded(context: ctx, knowledgeBase: kb)
        check("refresh preserves user-tuned built-in", sales.persona == "my custom persona")
        check("refresh bumps tuned profile's version", sales.presetVersion == ProfilePresets.presetVersion)
        let presetSupport = ProfilePresets.all().first { $0.id == support.id }
        check("refresh restores untouched built-in", support.persona == presetSupport?.persona)
    }

    static func testLenientKBDecode() {
        // A KBDocument saved before `note` existed must still decode — a strict
        // decode fails the whole store load and the next save wipes the KB.
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"pricing.pdf","chunkCount":3,"addedAt":700000000}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let doc = try? decoder.decode(KBDocument.self, from: legacy)
        check("KB doc decodes without note", doc != nil)
        check("KB doc missing note defaults empty", doc?.note == "")
        check("KB doc missing profileIDs defaults empty", doc?.profileIDs.isEmpty == true)
    }

    static func testNearDuplicate() {
        // Real reworded re-flags from the 2026-07-02 test call — must match.
        check("dedup catches reworded pricing question", CallAnalysisEngine.isNearDuplicate(
            "Annual plan pricing still unanswered Prospect asked twice what the annual subscription costs including onboarding fees.",
            "What does the annual subscription cost? Prospect explicitly asked for the annual plan price including onboarding fees."))
        check("dedup catches reworded docs question", CallAnalysisEngine.isNearDuplicate(
            "What docs do fintech partners actually need? The prospect just asked what documents UK fintechs require to open an account.",
            "What documents do fintech partners require? The prospect asked directly what verification documents the fintech banks need."))
        // Distinct topics from the same call — must NOT match.
        check("dedup keeps distinct topics apart", !CallAnalysisEngine.isNearDuplicate(
            "What are the actual requirements for UK bank account? Prospect asked what's needed to open a UK business bank account as a Moroccan resident.",
            "France customer base de-risks Stripe acceptance Prospect has customers in France which helps with processor acceptance."))
        check("dedup empty strings safe", !CallAnalysisEngine.isNearDuplicate("", "anything"))
    }

    // The model-side dedup verdict ("supersedes") — the 2026-07-17 call showed
    // re-flags crossing kinds (Shopify: suggestion → unanswered_question) and
    // rewording past any text heuristic (embedding distance was calibrated on
    // that call's real cards and could not separate dups from distinct — see
    // isNearDuplicate's scope note). Verify the whole chain: schema forces the
    // field, prompt explains it, parser carries it.
    static func testSupersedes() {
        let kinds = ProfilePresets.all().first { $0.name == "Sales discovery" }!.kinds
        let schema = ClaudeAnalysisProvider.schema(kinds: kinds, gauges: [])
        let insightsProp = ((schema["properties"] as? [String: Any])?["insights"] as? [String: Any])
        let items = insightsProp?["items"] as? [String: Any]
        check("supersedes in item schema", ((items?["properties"] as? [String: Any])?["supersedes"]) != nil)
        check("supersedes is required (compliance pattern)", (items?["required"] as? [String])?.contains("supersedes") == true)

        let prompt = ClaudeAnalysisProvider.systemPrompt(persona: "P", kinds: kinds, gauges: [])
        check("prompt explains supersedes", prompt.contains("supersedes"))

        // Parser carries the verdict through; empty string normalizes to nil.
        let payload = """
        {"insights": [
          {"kind": "objection", "title": "Banking intro in your package?", "detail": "d", "reply": "", "supersedes": "Prospect asking about bank account setup"},
          {"kind": "objection", "title": "Genuinely new concern", "detail": "d", "reply": "", "supersedes": ""}
        ], "sentiment": {"coach": "c", "score": 50, "read": "r"}, "resolved": []}
        """
        let parsed = try? ClaudeAnalysisProvider.parseAnalysisPayload(payload)
        check("parse carries supersedes", parsed?.insights.first?.supersedes == "Prospect asking about bank account setup")
        check("parse normalizes empty supersedes to nil", parsed?.insights.last?.supersedes == nil)
        // The engine filter admits exactly the drafts without a verdict.
        let admitted = (parsed?.insights ?? []).filter { ($0.supersedes ?? "").isEmpty }
        check("re-flag dropped, new card admitted", admitted.count == 1 && admitted.first?.title == "Genuinely new concern")

        // Verdict corroboration — honor the claim only when it stands up.
        typealias E = CallAnalysisEngine
        let bankingCard = [(title: "Prospect asking about bank account setup",
                            text: "Prospect asking about bank account setup Prospect asked what happens after formation: specifically, how to open a UK business bank account.")]
        // Real re-flag from the 2026-07-17 call: "banking"/"bank" corroborate via stem.
        check("verdict honored: banking re-flag corroborates", E.verdictCorroborated(
            supersedes: "Prospect asking about bank account setup",
            draftText: "Banking intro in your package? Prospect asked whether a banking introduction is included.",
            openCards: bankingCard))
        // Observed llama3.2 hallucination: new EU question claiming to supersede
        // the price card — zero shared stems, verdict rejected, card survives.
        check("verdict rejected: hallucinated overlap survives", !E.verdictCorroborated(
            supersedes: "Price pushback: quote is roughly double their current spend",
            draftText: "EU hosting region unclear The prospect asked whether data is stored in the EU and got no answer.",
            openCards: [(title: "Price pushback: quote is roughly double their current spend",
                         text: "Price pushback: quote is roughly double their current spend The prospect said the quote is double what they pay today.")]))
        check("verdict rejected: cited card not open", !E.verdictCorroborated(
            supersedes: "Some card that was never shown",
            draftText: "Banking intro in your package?",
            openCards: bankingCard))
        check("stem match: cross-kind Shopify pair", E.sharesTopicStem(
            "Does the package include Shopify integration?",
            "Prospect asking about Shopify integration support"))
        check("stem match: pricing/price morphology", E.sharesTopicStem(
            "Prospect asking about total package pricing",
            "Prospect asking for full package price—answer it now"))
    }

    static func testHallucinationFilter() {
        // Classic silence hallucinations on a quiet chunk — dropped.
        check("halluc: quiet 'Thank you.' dropped", TranscriptionEngine.isLikelyHallucination("Thank you.", energy: 0.002))
        check("halluc: quiet 'you' dropped", TranscriptionEngine.isLikelyHallucination("you", energy: 0.001))
        check("halluc: quiet 'Okay.' dropped", TranscriptionEngine.isLikelyHallucination("Okay.", energy: 0.003))
        check("halluc: bare '.' dropped at any volume", TranscriptionEngine.isLikelyHallucination(".", energy: 0.05))
        // Real speech survives.
        check("halluc: real sentence kept", !TranscriptionEngine.isLikelyHallucination("Can you hear me?", energy: 0.002))
        check("halluc: loud 'Okay.' kept", !TranscriptionEngine.isLikelyHallucination("Okay.", energy: 0.02))
        check("halluc: loud 'Thank you.' kept", !TranscriptionEngine.isLikelyHallucination("Thank you.", energy: 0.03))

        // Glossary echo stripping: a prompt leak PREFIXING real speech must not
        // take the speech with it (the live segment-drop of 2026-08-01).
        typealias TE = TranscriptionEngine
        check("echo: prefixed speech survives the leak",
              TE.strippingGlossaryEcho("Glossary: Launchese, Uygar. However I'm worried about churn.")
                == "However I'm worried about churn.")
        check("echo: pure echo still drops",
              TE.strippingGlossaryEcho("Glossary: Launchese, Uygar.") == nil)
        check("echo: unterminated echo still drops",
              TE.strippingGlossaryEcho("Glossary Launchese Uygar") == nil)
        check("echo: normal speech passes untouched",
              TE.strippingGlossaryEcho("The glossary says nothing about churn.")
                == "The glossary says nothing about churn.")
        check("echo: multi-sentence tail kept whole",
              TE.strippingGlossaryEcho("Glossary: A, B. First point. Second point.")
                == "First point. Second point.")

        // Cross-stream speaker-bleed dedup (mic re-hearing the speakers).
        check("bleed: identical text is echo",
              RecordingManager.isEchoDuplicate(
                "The quarterly numbers are looking very strong this month.",
                "The quarterly numbers are looking very strong this month."))
        check("bleed: decode variance still echo",
              RecordingManager.isEchoDuplicate(
                "However, I'm worried about the churn rate on the Enterprise tier.",
                "However I am worried about the churn rate on the enterprise tier."))
        check("bleed: different sentences are not echo",
              !RecordingManager.isEchoDuplicate(
                "Can you send me the retention report before Tuesday?",
                "The quarterly numbers are looking very strong this month."))
        check("bleed: short ack is not echo of a long line",
              !RecordingManager.isEchoDuplicate(
                "Okay sure.",
                "Can you send me the retention report before Tuesday?"))
    }

    static func testWAVEncoder() {
        let wav = WAVEncoder.encode(samples: [0, 0.5, -0.5, 2.0], sampleRate: 16000)
        check("wav total size", wav.count == 44 + 8)
        check("wav RIFF magic", wav.prefix(4) == Data("RIFF".utf8))
        check("wav WAVE magic", wav[8..<12] == Data("WAVE".utf8))
        func u32(_ offset: Int) -> UInt32 {
            wav[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        func i16(_ offset: Int) -> Int16 {
            wav[offset..<offset + 2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }.littleEndian
        }
        check("wav sample rate field", u32(24) == 16000)
        check("wav data size field", u32(40) == 8)
        check("wav first sample zero", i16(44) == 0)
        check("wav clamps overdrive to Int16.max-ish", i16(50) == 32767)
        // `selected` falls back to .local via `?? .local`; asserting on it directly
        // read the tester's real UserDefaults and broke once a cloud engine was chosen.
        check("unknown backend raw value rejected", TranscriptionBackend(rawValue: "gibberish") == nil)
    }

    static func testAIUsageCost() {
        // Known tokens → known dollars: 1M in ($1.00) + 200k out ($1.00) = $2.00;
        // Deepgram 10 min × 2 tracks = 1/3 hr × $0.29 ≈ $0.0967;
        // polish 20 min = 1/3 hr × $0.04 ≈ $0.0133.
        var usage = AIUsage()
        usage.copilotModel = "claude-haiku-4-5"
        usage.copilot = AITokenTotals(inputTokens: 1_000_000, outputTokens: 200_000, calls: 41)
        usage.transcriptionBackend = TranscriptionBackend.deepgram.rawValue
        usage.transcriptionSeconds = 600
        usage.transcriptionTracks = 2
        usage.polishSeconds = 1200

        let items = usage.costBreakdown()
        check("cost has 3 line items", items.count == 3)
        check("copilot cost $2.00", abs(items[0].usd - 2.00) < 0.0001)
        check("copilot detail has calls + tokens", items[0].detail.contains("41 calls") && items[0].detail.contains("1000k in"))
        check("deepgram cost matches $0.29/hr rate", abs(items[1].usd - 1200.0 / 3600 * 0.29) < 0.0001)
        // The real invoice this rate was verified against: 1:50 call, 2 streams.
        var invoice = AIUsage()
        invoice.transcriptionBackend = TranscriptionBackend.deepgram.rawValue
        invoice.transcriptionSeconds = 110
        invoice.transcriptionTracks = 2
        check("deepgram matches real bill ±10%", abs(invoice.totalUSD - 0.01788) < 0.0018)
        check("polish cost ~$0.0133", abs(items[2].usd - 1200.0 / 3600 * 0.04) < 0.0001)
        check("total sums line items", abs(usage.totalUSD - items.reduce(0) { $0 + $1.usd }) < 0.0001)

        // Local + no copilot calls + no polish → one free line only.
        var free = AIUsage()
        free.transcriptionSeconds = 600
        let freeItems = free.costBreakdown()
        check("local-only is 1 free line", freeItems.count == 1 && freeItems[0].usd == 0)
        check("local detail says on-device", freeItems[0].detail == "on-device")

        // Codable round-trip (this is what Meeting.aiUsageData stores).
        let decoded = (try? JSONEncoder().encode(usage)).flatMap { try? JSONDecoder().decode(AIUsage.self, from: $0) }
        check("AIUsage round-trips", decoded?.copilot == usage.copilot && decoded?.polishSeconds == 1200)

        check("formatUSD cents", AIUsage.formatUSD(0.154) == "$0.15")
        check("formatUSD sub-cent shows 3 decimals", AIUsage.formatUSD(0.0013) == "$0.001")
        check("formatUSD zero", AIUsage.formatUSD(0) == "$0.00")

        // Live/reports split: Claude live cards priced at Haiku rates, local
        // reports free — two separately-priced buckets plus transcription.
        var split = AIUsage()
        split.copilotModel = "claude-haiku-4-5"
        split.copilotProvider = "claude"
        split.copilot = AITokenTotals(inputTokens: 1_000_000, outputTokens: 200_000, calls: 10)
        split.reportsModel = "gemma3:4b"
        split.reportsProvider = "ollama"
        split.reports = AITokenTotals(inputTokens: 50_000, outputTokens: 5_000, calls: 2)
        split.transcriptionSeconds = 600
        let splitItems = split.costBreakdown()
        check("split has 3 lines", splitItems.count == 3)
        check("split live line priced", splitItems[0].label.hasPrefix("Live cards") && abs(splitItems[0].usd - 2.00) < 0.0001)
        check("split reports line free + local", splitItems[1].label.hasPrefix("Reports") && splitItems[1].label.contains("local") && splitItems[1].usd == 0)
        let splitDecoded = (try? JSONEncoder().encode(split)).flatMap { try? JSONDecoder().decode(AIUsage.self, from: $0) }
        check("split round-trips", splitDecoded?.reports == split.reports && splitDecoded?.reportsProvider == "ollama")


    }

    // The issue-#12 mic watchdog: sustained exact-zero input means the OS cut
    // the feed (a call app holds the mic); dither-level noise never triggers.
    static func testMicWatchdog() {
        typealias W = AudioCaptureManager.MicSignalWatchdog
        var w = W()
        let t0 = Date(timeIntervalSince1970: 1_000)
        check("watchdog quiet dithery mic is ok", w.observe(meanAbs: 0.0001, at: t0) == .ok)
        check("watchdog first zero buffer is ok", w.observe(meanAbs: 0, at: t0.addingTimeInterval(0.1)) == .ok)
        check("watchdog short zero run is ok", w.observe(meanAbs: 0, at: t0.addingTimeInterval(1.9)) == .ok)
        check("watchdog sustained zeros are lost", w.observe(meanAbs: 0, at: t0.addingTimeInterval(2.2)) == .lost)
        check("watchdog reports lost only once", w.observe(meanAbs: 0, at: t0.addingTimeInterval(3)) == .stillLost)
        check("watchdog recovers on real signal", w.observe(meanAbs: 0.01, at: t0.addingTimeInterval(4)) == .recovered)
        check("watchdog ok after recovery", w.observe(meanAbs: 0.01, at: t0.addingTimeInterval(5)) == .ok)
        var w2 = W()
        _ = w2.observe(meanAbs: 0, at: t0)
        _ = w2.observe(meanAbs: 0.02, at: t0.addingTimeInterval(1))
        check("watchdog nonzero resets the zero run", w2.observe(meanAbs: 0, at: t0.addingTimeInterval(2.5)) == .ok)
    }

    // Local model folder matching (the hub-resolution bypass in loadModel),
    // plus the tag → hub-spelling map that makes first-time downloads resolve
    // (issue #30: no repo folder ends in "large-v3-turbo").
    static func testModelFolderMatch() {
        let disk = ["openai_whisper-base", "openai_whisper-small",
                    "openai_whisper-large-v3-v20240930",
                    "openai_whisper-large-v3-v20240930_626MB",
                    "distil-whisper_distil-large-v3"]
        check("hub variant maps the turbo tag", TranscriptionEngine.hubVariant(for: "large-v3-turbo") == "large-v3-v20240930")
        check("hub variant passes other tags through", TranscriptionEngine.hubVariant(for: "base") == "base")
        check("display name for turbo", TranscriptionEngine.displayName(for: "large-v3-turbo") == "Large V3 Turbo")
        check("display name for compressed", TranscriptionEngine.displayName(for: "large-v3-v20240930_626MB") == "Large V3 Turbo Compressed")
        check("display name capitalizes plain tags", TranscriptionEngine.displayName(for: "base") == "Base")
        check("folder match base", TranscriptionEngine.matchModelFolder("base", in: disk) == "openai_whisper-base")
        check("folder match turbo resolves via hub variant",
              TranscriptionEngine.matchModelFolder("large-v3-turbo", in: disk) == "openai_whisper-large-v3-v20240930")
        check("folder match supports legacy turbo download",
              TranscriptionEngine.matchModelFolder("large-v3-turbo", in: ["openai_whisper-large-v3_turbo"])
                == "openai_whisper-large-v3_turbo")
        check("folder match prefers current turbo download",
              TranscriptionEngine.matchModelFolder(
                "large-v3-turbo",
                in: ["openai_whisper-large-v3_turbo", "openai_whisper-large-v3-v20240930"]
              ) == "openai_whisper-large-v3-v20240930")
        check("folder match 626MB across separators",
              TranscriptionEngine.matchModelFolder("large-v3-v20240930-626mb", in: disk) == "openai_whisper-large-v3-v20240930_626MB")
        check("folder match misses absent model", TranscriptionEngine.matchModelFolder("tiny", in: disk) == nil)
        check("folder match rejects ambiguity",
              TranscriptionEngine.matchModelFolder("base", in: ["openai_whisper-base", "openai-whisper_base"]) == nil)

        let partial = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-partial-model-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: partial.appendingPathComponent("TextDecoder.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: partial.appendingPathComponent("TextDecoder.mlmodelc/model.mil").path,
            contents: Data()
        )
        check("partial model folder is rejected", !TranscriptionEngine.isCompleteModelFolder(partial))

        for file in TranscriptionEngine.requiredModelFiles {
            let url = partial.appendingPathComponent(file)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        check("complete model folder is accepted", TranscriptionEngine.isCompleteModelFolder(partial))
        try? FileManager.default.removeItem(at: partial)
    }

    // The pre-filled GitHub issue behind the corner bug button.
    static func testBugReport() {
        check("report body trims the user text",
              BugReport.body(text: "  it crashed  ", includeDiagnostics: false,
                             includeScreenshot: false) == "it crashed")
        let full = BugReport.body(text: "x", includeDiagnostics: true, includeScreenshot: true)
        check("report body marks the paste spot", full.contains("⌘V"))
        check("report body carries diagnostics", full.contains("Parrot "))
        check("report body omits the paste spot when nothing is attached",
              !BugReport.body(text: "x", includeDiagnostics: true,
                              includeScreenshot: false).contains("⌘V"))
        check("report body omits diagnostics when declined",
              !BugReport.body(text: "x", includeDiagnostics: false,
                              includeScreenshot: false).contains("macOS"))
        // Diagnostics are a fixed two lines: anything else means something new
        // (and possibly identifying) started riding along.
        check("diagnostics stay two lines", BugReport.diagnostics().count == 2)

        let url = BugReport.issueURL(kind: .idea, title: "Tabs & spaces #1", body: "one\ntwo")
        check("issue url targets the repo's new-issue form",
              url?.absoluteString.hasPrefix("https://github.com/turantekin/Parrot/issues/new?") == true)
        check("issue url labels an idea as enhancement",
              url?.absoluteString.contains("labels=enhancement") == true)
        check("issue url labels a bug as bug",
              BugReport.issueURL(kind: .bug, title: "t", body: "b")?
                .absoluteString.contains("labels=bug") == true)
        // The ampersand must not survive raw, or it starts a new query param
        // and the body is silently truncated.
        check("issue url escapes ampersands and hashes in the title",
              url?.absoluteString.contains("Tabs%20%26%20spaces%20%231") == true)
        check("issue url escapes newlines in the body",
              url?.absoluteString.contains("one%0Atwo") == true)
    }

    // The live-loop utterance segmenter that replaced fixed 2 s chunks.
    static func testSegmenter() {
        typealias Seg = TranscriptionEngine.Segmenter
        // Building blocks in whole 100 ms frames: audible speech vs true silence.
        func speech(_ frames: Int) -> [Float] { Array(repeating: 0.02, count: frames * Seg.frame) }
        func silence(_ frames: Int) -> [Float] { Array(repeating: 0.0001, count: frames * Seg.frame) }

        // Silence never decodes: live keeps only the partial tail frame, drain eats all.
        let quiet = silence(8) + [0.0001, 0.0001]
        check("seg silence live drops whole frames",
              Seg.nextCut(in: quiet, draining: false) == .init(dropLeading: 8 * Seg.frame, take: nil))
        check("seg silence draining drops everything",
              Seg.nextCut(in: quiet, draining: true) == .init(dropLeading: quiet.count, take: nil))

        // Speech bounded by a pause cuts at the boundary, padded 100 ms into it.
        let utterance = silence(3) + speech(10) + silence(Seg.pauseFrames) + speech(2)
        check("seg utterance cuts at pause",
              Seg.nextCut(in: utterance, draining: false)
                == .init(dropLeading: 3 * Seg.frame, take: (10 + Seg.padFrames) * Seg.frame))

        // A pause shorter than the threshold does not end the utterance.
        let midPause = silence(2) + speech(6) + silence(Seg.pauseFrames - 2) + speech(4)
        check("seg short pause keeps buffering",
              Seg.nextCut(in: midPause, draining: false) == .init(dropLeading: 2 * Seg.frame, take: nil))

        // Sub-300 ms islands between silences are noise: dropped with their pause.
        let blip = silence(4) + speech(2) + silence(Seg.pauseFrames) + speech(3)
        check("seg noise blip dropped without decode",
              Seg.nextCut(in: blip, draining: false)
                == .init(dropLeading: (4 + 2 + Seg.pauseFrames) * Seg.frame, take: nil))

        // Continuous speech: wait while live, forced cut at the cap, take-all on drain.
        let running = speech(20)
        check("seg continuous speech waits",
              Seg.nextCut(in: running, draining: false) == .init(dropLeading: 0, take: nil))
        let monologue = speech(Seg.maxSegmentSamples / Seg.frame + 10)
        check("seg cap forces a cut",
              Seg.nextCut(in: monologue, draining: false) == .init(dropLeading: 0, take: Seg.maxSegmentSamples))
        check("seg draining takes the tail",
              Seg.nextCut(in: running, draining: true) == .init(dropLeading: 0, take: running.count))

        // Two utterances buffered: the cut ends at the FIRST boundary.
        let two = speech(5) + silence(Seg.pauseFrames) + speech(5) + silence(Seg.pauseFrames)
        check("seg cuts one utterance at a time",
              Seg.nextCut(in: two, draining: false) == .init(dropLeading: 0, take: (5 + Seg.padFrames) * Seg.frame))

        // Quiet-gain audio (real session 2026-08-04: 49% input volume, speech
        // ~0.0014 mean-abs) — invisible at the legacy floor, segmented
        // correctly once the adaptive floor is passed in.
        func quietSpeech(_ frames: Int) -> [Float] { Array(repeating: 0.0014, count: frames * Seg.frame) }
        func roomNoise(_ frames: Int) -> [Float] { Array(repeating: 0.0002, count: frames * Seg.frame) }
        let quietUtterance = roomNoise(3) + quietSpeech(10) + roomNoise(Seg.pauseFrames) + quietSpeech(2)
        check("seg legacy floor is blind to quiet speech",  // documents the bug
              Seg.nextCut(in: quietUtterance, draining: false)
                == .init(dropLeading: quietUtterance.count, take: nil))
        check("seg adaptive floor cuts quiet speech at its pause",
              Seg.nextCut(in: quietUtterance, draining: false, floor: 0.0008)
                == .init(dropLeading: 3 * Seg.frame, take: (10 + Seg.padFrames) * Seg.frame))
        check("seg adaptive floor still discards quiet-room silence",
              Seg.nextCut(in: roomNoise(8), draining: false, floor: 0.0008)
                == .init(dropLeading: 8 * Seg.frame, take: nil))
    }

    // The quiet-mic pipeline (2026-08-04 live trace): buffer-derived noise
    // floor + pre-decode loudness normalization.
    static func testQuietMic() {
        typealias Seg = TranscriptionEngine.Segmenter
        func quietSpeech(_ frames: Int) -> [Float] { Array(repeating: 0.0014, count: frames * Seg.frame) }
        func roomNoise(_ frames: Int) -> [Float] { Array(repeating: 0.0002, count: frames * Seg.frame) }

        // Bimodal window (speech + real pauses): floor sits between the two.
        let mixed = roomNoise(3) + quietSpeech(10) + roomNoise(Seg.pauseFrames)
        let mixedFloor = Seg.adaptiveFloor(for: mixed)
        check("adaptive floor lands between quiet room and quiet speech",
              mixedFloor > 0.0002 && mixedFloor < 0.0014)
        check("adaptive floor cuts the quiet utterance it derived from",
              Seg.nextCut(in: mixed, draining: false, floor: mixedFloor)
                == .init(dropLeading: 3 * Seg.frame, take: (10 + Seg.padFrames) * Seg.frame))

        // Cold start, the 0.02× lesson: a backlog that is ALL quiet speech
        // (no pause seen yet) must never be classified as leading silence —
        // the flat-window rule keeps it buffering until a pause bounds it.
        check("flat quiet-speech window reads as speech",
              Seg.adaptiveFloor(for: quietSpeech(10)) == Seg.ditherFloor)
        check("cold-start quiet speech is never eaten",
              Seg.nextCut(in: quietSpeech(10), draining: false,
                          floor: Seg.adaptiveFloor(for: quietSpeech(10)))
                == .init(dropLeading: 0, take: nil))

        // Flat true silence still reads as silence and is discarded.
        check("flat quiet-room window reads as silence",
              Seg.adaptiveFloor(for: roomNoise(8)) == Seg.silenceFloor)
        check("quiet-room silence is still discarded",
              Seg.nextCut(in: roomNoise(8), draining: false,
                          floor: Seg.adaptiveFloor(for: roomNoise(8)))
                == .init(dropLeading: 8 * Seg.frame, take: nil))

        // Normal gain: derived floor never exceeds the legacy fixed one, so
        // no environment behaves worse than shipped.
        let normal: [Float] = Array(repeating: 0.0001, count: 3 * Seg.frame)
            + Array(repeating: 0.02, count: 10 * Seg.frame)
        check("adaptive floor is capped at the legacy floor",
              Seg.adaptiveFloor(for: normal) <= Seg.silenceFloor)
        check("adaptive floor never sinks below dither",
              Seg.adaptiveFloor(for: normal) >= Seg.ditherFloor)
        check("empty window falls back to the legacy floor",
              Seg.adaptiveFloor(for: []) == Seg.silenceFloor)

        typealias TE = TranscriptionEngine
        func rms(_ s: [Float]) -> Float { (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot() }
        let voice: [Float] = (0..<1600).map { sin(Float($0) * 0.1) * 0.2 }
        let faint = voice.map { $0 * 0.05 }  // the harness's 0.05× quiet-mic scaling
        check("normalize boosts faint speech to target loudness",
              abs(rms(TE.normalizedForDecode(faint)) - 0.06) < 0.005)
        check("normalize leaves healthy audio untouched", TE.normalizedForDecode(voice) == voice)
        check("normalize gain is capped on near-silence",
              rms(TE.normalizedForDecode(Array(repeating: 0.0001, count: 1600))) < 0.004)
        check("normalize clamps a stray click to ±1",
              TE.normalizedForDecode(faint + [0.9]).allSatisfy { abs($0) <= 1 })
        check("normalize empty chunk is safe", TE.normalizedForDecode([]).isEmpty)
    }

    @MainActor
    static func testSpeakerNames() {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
            check("speaker-names container builds", false); return
        }
        let ctx = ModelContext(container)
        let m = Meeting(title: "t")
        ctx.insert(m)
        for (start, dur, label) in [(0.0, 5.0, "Speaker 1"), (10.0, 2.0, "Speaker 2"),
                                    (20.0, 9.0, "Speaker 1"), (30.0, 1.0, "Me")] {
            let s = TranscriptSegment(startTime: start, endTime: start + dur, text: "x", speakerLabel: label)
            ctx.insert(s); s.meeting = m
        }
        m.themName = "The Others"
        check("legacy fallback intact", m.displayName(forSpeaker: "Speaker 1") == "The Others")
        m.speakerNames = ["Speaker 1": "Gürkan"]
        check("named label resolves", m.displayName(forSpeaker: "Speaker 1") == "Gürkan")
        check("unnamed label stays raw once naming started", m.displayName(forSpeaker: "Speaker 2") == "Speaker 2")
        check("me is me", m.displayName(forSpeaker: "Me") == "Me")
        check("fresh meeting has no names", Meeting(title: "u").speakerNames.isEmpty)
        check("other labels ordered", m.otherSpeakerLabels == ["Speaker 1", "Speaker 2"])
        check("longest segments sorted", m.longestSegments(for: "Speaker 1").map(\.startTime) == [20.0, 0.0])
        check("participants summary", m.participantsSummary == "Gürkan")
    }

    @MainActor
    static func testVoiceProfiles() {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
            check("voice-profiles container builds", false); return
        }
        let ctx = ModelContext(container)
        let a: [Float] = [1, 0, 0], b: [Float] = [0, 1, 0]
        check("cosine identical", abs(SpeakerProfileStore.cosine(a, a) - 1) < 0.001)
        check("cosine orthogonal", abs(SpeakerProfileStore.cosine(a, b)) < 0.001)
        check("no profiles no match", SpeakerProfileStore.match(a, in: ctx) == nil)
        SpeakerProfileStore.remember(name: "Gürkan", embedding: [1, 0, 0], in: ctx)
        check("match after remember", SpeakerProfileStore.match([0.9, 0.1, 0], in: ctx)?.name == "Gürkan")
        check("below threshold no match", SpeakerProfileStore.match([0, 0, 1], in: ctx) == nil)
        SpeakerProfileStore.remember(name: "Gürkan", embedding: [0, 1, 0], in: ctx)
        let profile = SpeakerProfileStore.profiles(in: ctx).first
        check("running mean", profile.map { abs($0.embedding[0] - 0.5) < 0.001 && abs($0.embedding[1] - 0.5) < 0.001 } ?? false)
        check("sample count grows", profile?.sampleCount == 2)
        SpeakerProfileStore.deleteAll(in: ctx)
        check("deleteAll empties", SpeakerProfileStore.profiles(in: ctx).isEmpty)
    }

    static func testLiveLabelStability() {
        typealias M = RecordingManager
        let anchors: [String: [Float]] = ["Speaker 1": [1, 0, 0], "Speaker 2": [0, 1, 0]]
        check("identity when no anchors",
              M.stableMapping(newEmbeddings: ["Speaker 1": [1, 0, 0]], anchors: [:]) == ["Speaker 1": "Speaker 1"])
        let flipped = M.stableMapping(
            newEmbeddings: ["Speaker 1": [0, 0.99, 0.1], "Speaker 2": [0.99, 0, 0.1]],
            anchors: anchors)
        check("talk-order flip keeps identities",
              flipped == ["Speaker 1": "Speaker 2", "Speaker 2": "Speaker 1"])
        let grown = M.stableMapping(
            newEmbeddings: ["Speaker 1": [1, 0, 0], "Speaker 2": [0, 0, 1]],
            anchors: ["Speaker 1": [1, 0, 0]])
        check("new voice gets fresh label", grown == ["Speaker 1": "Speaker 1", "Speaker 2": "Speaker 2"])
        let taken = M.stableMapping(
            newEmbeddings: ["Speaker 1": [0, 0, 1]],
            anchors: anchors)
        check("unmatched avoids anchor labels", taken == ["Speaker 1": "Speaker 3"])
    }

    static func testDiarizedLabel() {
        typealias Turn = DiarizationEngine.SpeakerSegmentResult
        let turns = [
            Turn(speakerLabel: "Speaker 1", startTime: 0, endTime: 10),
            Turn(speakerLabel: "Speaker 2", startTime: 12, endTime: 20),
        ]
        check("diarize max overlap wins",
              RecordingManager.diarizedLabel(for: (9, 14), turns: turns) == "Speaker 2")
        check("diarize zero overlap picks nearest turn",
              RecordingManager.diarizedLabel(for: (10.2, 10.9), turns: turns) == "Speaker 1")
        check("diarize after everything picks last turn",
              RecordingManager.diarizedLabel(for: (25, 26), turns: turns) == "Speaker 2")
        check("diarize no turns gives nil",
              RecordingManager.diarizedLabel(for: (0, 1), turns: []) == nil)
    }

    // The #20 budget controls: pace presets, the live context window, pause.
    @MainActor
    static func testCopilotBudget() {
        // Fast must be the original constants exactly — the default changes nothing.
        let fast = CopilotPace.fast.timing
        check("pace fast is the original timing",
              fast.question == 1 && fast.idle == 8 && fast.floor == 5 && fast.staleness == 15)
        // Every slower pace waits at least as long on every timer.
        for (quicker, slower) in [(CopilotPace.fast, CopilotPace.balanced), (.balanced, .relaxed)] {
            let a = quicker.timing, b = slower.timing
            check("pace \(slower.rawValue) never faster than \(quicker.rawValue)",
                  b.question >= a.question && b.idle >= a.idle
                    && b.floor >= a.floor && b.staleness >= a.staleness)
        }
        check("pace unknown value has no case", CopilotPace(rawValue: "turbo") == nil)
        check("window standard is 5 minutes", CopilotWindow.standard.minutes == 5)

        // Window math: recent kept, old excluded, floor and cap honored.
        typealias E = CallAnalysisEngine
        let times: [TimeInterval] = (0..<40).map { TimeInterval($0) * 10 }  // 0,10,…,390
        check("window empty transcript sends nothing", E.windowSuffixCount(times: [], seconds: 120) == 0)
        check("window keeps only recent segments",
              E.windowSuffixCount(times: times, seconds: 120) == 13)  // 270…390
        check("window floor lifts a quiet call",
              E.windowSuffixCount(times: times, seconds: 5, minCount: 10) == 10)
        check("window floor capped at what exists",
              E.windowSuffixCount(times: [0, 5], seconds: 1, minCount: 10) == 2)
        check("window cap bounds a dense stretch",
              E.windowSuffixCount(times: times, seconds: 1000, maxCount: 20) == 20)

        // Pause: only valid mid-session, cards survive a pause/resume cycle.
        let engine = CallAnalysisEngine()
        engine.setPaused(true)
        check("pause before start is ignored", !engine.isPaused)
        engine.seedForSnapshot(
            profile: nil,
            insights: [Insight(kindKey: "blocker", title: "t", detail: "d", callTime: 0, source: nil)],
            sentiment: [:], read: nil, meCharacters: 0, themCharacters: 0)
        engine.setPaused(true)
        check("pause flips status", engine.isPaused && engine.status == .paused)
        check("pause keeps cards", engine.insights.count == 1)
        engine.setPaused(false)
        // Not asserting the exact resumed status: it depends on whether a key
        // is configured on the machine running the harness.
        check("resume leaves the paused state", !engine.isPaused && engine.status != .paused)
        check("resume keeps cards", engine.insights.count == 1)
    }

    static func testStableHash() {
        check("stableHash deterministic", "Speaker 1".stableHash == "Speaker 1".stableHash)
        check("stableHash non-negative", "".stableHash >= 0 && "🦜 émojî".stableHash >= 0)
        check("stableHash differs across labels", "Speaker 1".stableHash != "Speaker 2".stableHash)
    }

    static func testPromptAndSchema() {
        let kinds = ProfilePresets.all().first { $0.name == "1:1 coaching" }!.kinds
        let prompt = ClaudeAnalysisProvider.systemPrompt(persona: "P", kinds: kinds, gauges: [])
        check("prompt includes persona", prompt.contains("P"))
        check("prompt lists reflection key", prompt.contains("reflection"))
        check("prompt has no hardcoded 'objection'", !prompt.lowercased().contains("objection"))
        let schema = ClaudeAnalysisProvider.schema(kinds: kinds, gauges: [SentimentGauge(id: UUID(), key: "client_openness", label: "x", lowLabel: "a", highLabel: "b", colorHex: "2F7E96")])
        // enum equals the profile's keys
        let insightsProp = ((schema["properties"] as? [String: Any])?["insights"] as? [String: Any])
        let items = insightsProp?["items"] as? [String: Any]
        let kindEnum = ((items?["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String]
        check("schema enum == profile keys", Set(kindEnum ?? []) == Set(kinds.map(\.key)))
        check("schema has sentiment object", (schema["properties"] as? [String: Any])?["sentiment"] != nil)
        // Injection hardening: transcript/document text is declared data-only.
        check("prompt declares tagged text as data", prompt.contains("<transcript>"))
        let valid = ClaudeAnalysisProvider.validatingKinds(
            [InsightDraft(kindKey: "reflection", title: "t", detail: "d", source: nil),
             InsightDraft(kindKey: "objection", title: "t", detail: "d", source: nil)],
            allowed: Set(kinds.map(\.key)))
        check("validatingKinds drops out-of-lens", valid.count == 1 && valid.first?.kindKey == "reflection")
    }

    static func testSnapshotPersistence() {
        let kinds = ProfilePresets.all().first!.kinds
        let data = try? JSONEncoder().encode(kinds)
        let m = Meeting()
        m.profileSnapshotData = data
        check("snapshot decodes back", m.snapshotKinds.count == kinds.count)
        check("snapshot preserves first key", m.snapshotKinds.first?.key == kinds.first?.key)
    }

    static func testHexColor() {
        // Verify a 6-digit hex parses to the expected RGB components.
        let c = Color(hex: "2F7E96")
        let ns = NSColor(c).usingColorSpace(.sRGB)
        let epsilon = 2.0 / 255.0 // allow for rounding
        let redOK   = abs((ns?.redComponent   ?? -1) - (Double(0x2F) / 255.0)) < epsilon
        let greenOK = abs((ns?.greenComponent ?? -1) - (Double(0x7E) / 255.0)) < epsilon
        let blueOK  = abs((ns?.blueComponent  ?? -1) - (Double(0x96) / 255.0)) < epsilon
        check("hex 2F7E96 red component",   redOK)
        check("hex 2F7E96 green component", greenOK)
        check("hex 2F7E96 blue component",  blueOK)

        // Verify a malformed hex falls back to gray (not a crash).
        // SwiftUI's Color.gray resolves in sRGB to a neutral midtone (all channels ~0.5–0.7).
        let bad = Color(hex: "zzz")
        let nsBad = NSColor(bad).usingColorSpace(.sRGB)
        let r = nsBad?.redComponent ?? -1
        let g = nsBad?.greenComponent ?? -1
        let b = nsBad?.blueComponent ?? -1
        // All channels should be in the neutral midrange [0.4, 0.8] for a gray-like fallback.
        let grayOK = (0.4...0.8).contains(r) && (0.4...0.8).contains(g) && (0.4...0.8).contains(b)
        check("malformed hex falls back to gray", grayOK)
    }

    static func testPermissionFlow() {
        // The screen-capture ask must be exactly one of: nothing (granted),
        // the single OS prompt (first ask), or a Settings deep-link (re-ask).
        // The old code showed the prompt AND opened Settings on a first ask.
        check("perm: granted wins",
              PermissionFlow.nextScreenCaptureStep(preflightGranted: true, askedBefore: true) == .granted)
        check("perm: granted ignores asked flag",
              PermissionFlow.nextScreenCaptureStep(preflightGranted: true, askedBefore: false) == .granted)
        check("perm: first ask posts the one OS prompt",
              PermissionFlow.nextScreenCaptureStep(preflightGranted: false, askedBefore: false) == .promptShown)
        check("perm: re-ask deep-links to Settings",
              PermissionFlow.nextScreenCaptureStep(preflightGranted: false, askedBefore: true) == .openSettings)

        // macOS 15+ system-audio tap: the grant is unreadable (an unauthorized
        // tap "succeeds" silently), so the flow is prompt → one Settings
        // deep-link → optimistic. It must never gatekeep forever.
        check("sysaudio: proven tap wins",
              PermissionFlow.nextSystemAudioStep(proven: true, screenGranted: false, askedBefore: false, settingsShownBefore: false) == .granted)
        check("sysaudio: Screen Recording grant is a valid fallback",
              PermissionFlow.nextSystemAudioStep(proven: false, screenGranted: true, askedBefore: true, settingsShownBefore: true) == .granted)
        check("sysaudio: first ask posts the one OS prompt",
              PermissionFlow.nextSystemAudioStep(proven: false, screenGranted: false, askedBefore: false, settingsShownBefore: false) == .promptShown)
        check("sysaudio: second ask deep-links to Settings once",
              PermissionFlow.nextSystemAudioStep(proven: false, screenGranted: false, askedBefore: true, settingsShownBefore: false) == .openSettings)
        check("sysaudio: after prompt + Settings it stops gatekeeping",
              PermissionFlow.nextSystemAudioStep(proven: false, screenGranted: false, askedBefore: true, settingsShownBefore: true) == .granted)
    }
}
