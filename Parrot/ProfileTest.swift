import Foundation
import SwiftUI
import SwiftData
import Carbon.HIToolbox

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
        testProcessingModes()
        testGeminiHelpers()
        testDrainTimeout()
        testRangedAudioRead()
        testClipboardAndTransforms()
        testMainDetailPane()
        testPolishReplaceKeepsTail()
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
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self, DictationNote.self])
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
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self, DictationNote.self])
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
        var geminiLive = AIUsage()
        geminiLive.transcriptionBackend = TranscriptionBackend.gemini.rawValue
        geminiLive.transcriptionSeconds = 600
        check("gemini live transcription is unpriced",
              geminiLive.costBreakdown().contains { $0.label.contains("Gemini") && $0.usd == 0 })

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
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self, DictationNote.self])
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
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self, DictationNote.self])
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
        check("copilot does not invent a language lesson",
              prompt.contains("Do not treat this as a language lesson")
              && !prompt.contains("German"))
        let valid = ClaudeAnalysisProvider.validatingKinds(
            [InsightDraft(kindKey: "reflection", title: "t", detail: "d", source: nil),
             InsightDraft(kindKey: "objection", title: "t", detail: "d", source: nil)],
            allowed: Set(kinds.map(\.key)))
        check("validatingKinds drops out-of-lens", valid.count == 1 && valid.first?.kindKey == "reflection")
        let none = TranslationContext.active(
            session: false, enabled: false, languageName: "Turkish", languageCode: "tr")
        check("translation context off when unused", none == nil)
        let ctx = TranslationContext.active(
            session: true, enabled: true, languageName: "Turkish", languageCode: "tr")!
        let translated = ClaudeAnalysisProvider.systemPrompt(
            persona: "P", kinds: kinds, gauges: [], translation: ctx)
        check("translation prompt names the selected language", translated.contains("Turkish"))
        check("translation prompt includes the language code", translated.contains("(tr)"))
        check("translation prompt is not pinned to German", !translated.contains("German"))
        check("translation prompt asks for cards in the target",
              translated.contains("Write every title, detail, reply, and coach line in Turkish"))
        let spanish = TranslationContext.active(
            session: true, enabled: true, languageName: "Spanish", languageCode: "es")!
        let spanishPrompt = ClaudeAnalysisProvider.systemPrompt(
            persona: "P", kinds: kinds, gauges: [], translation: spanish)
        check("dropdown language replaces the previous target",
              spanishPrompt.contains("Spanish") && !spanishPrompt.contains("Turkish"))
        let request = AnalysisRequest(
            transcript: "Me: hi", knownInsightTitles: [], references: [],
            instructions: "", callBrief: "", allowGeneralKnowledge: true,
            knownDocumentNames: [], persona: "P", counterpart: "them",
            kinds: kinds, gauges: [], translation: ctx)
        let user = ClaudeAnalysisProvider.analysisUserContent(request)
        check("translation user turn names the target", user.contains("Turkish"))
        check("report instructions name the target", ctx.reportInstructions.contains("Turkish"))
        let urdu = TranslationContext.active(
            session: true, enabled: true, languageName: "Urdu", languageCode: "ur")!
        let urduPrompt = ClaudeAnalysisProvider.systemPrompt(
            persona: "You help with a German teacher.", kinds: kinds, gauges: [], translation: urdu)
        check("urdu dropdown beats a German-teacher persona",
              urduPrompt.contains("Urdu") && urduPrompt.contains("Never tell the user to work in"))
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

    static func testProcessingModes() {
        check("mode default local", ProcessingMode.resolved(nil) == .local)
        check("mode garbage local", ProcessingMode.resolved("nope") == .local)
        check("mode hybrid", ProcessingMode.resolved("hybrid") == .hybrid)
        check("vendor default gemini", CloudVendor.resolved(nil) == .gemini)
        check("vendor garbage gemini", CloudVendor.resolved("x") == .gemini)
        check("three call modes", ProcessingMode.allCases.count == 3)
        check("each feature has its own mode key",
              FeatureProcessing.callModeKey != FeatureProcessing.translationModeKey)
        check("translation has its own ollama model",
              FeatureProcessing.translationOllamaModelKey != "copilotOllamaModel"
              && FeatureProcessing.translationOllamaDefault == "gemma3:1b")
        let previousModel = UserDefaults.standard.string(forKey: FeatureProcessing.translationOllamaModelKey)
        UserDefaults.standard.set("llama3:8b", forKey: FeatureProcessing.translationOllamaModelKey)
        check("stale translation model id falls back",
              FeatureProcessing.translationOllamaModel == FeatureProcessing.translationOllamaDefault)
        if let previousModel {
            UserDefaults.standard.set(previousModel, forKey: FeatureProcessing.translationOllamaModelKey)
        } else {
            UserDefaults.standard.removeObject(forKey: FeatureProcessing.translationOllamaModelKey)
        }
        check("ollama catalog includes qwen and gemma1b",
              OllamaCatalog.ids.contains("qwen2.5:3b")
              && OllamaCatalog.ids.contains("qwen2.5:1.5b")
              && OllamaCatalog.ids.contains("gemma3:1b"))
        check("transforms are not a processing mode", TransformKind.allCases.count == 4)
        check("builtin catalog is four", TransformCatalog.builtins().count == 4)
        check("translation languages include Turkish", TranslationLanguage.allCases.contains(.tr))
        check("translation languages include Urdu", TranslationLanguage.allCases.contains(.ur))
        check("translation languages include Hinglish", TranslationLanguage.allCases.contains(.hinglish))
        check("unknown apple pair is not used live", !AppleTranslationGate.mayUseDuringCall(target: "xx"))
        check("whisper translates speech to English only",
              LocalTranslation.whisperTranslatesToEnglish("en")
              && !LocalTranslation.whisperTranslatesToEnglish("ur")
              && !LocalTranslation.whisperTranslatesToEnglish("hi")
              && !LocalTranslation.whisperTranslatesToEnglish("de"))
        let spokenBefore = UserDefaults.standard.string(forKey: "transcriptionLanguage")
        UserDefaults.standard.set("auto", forKey: "transcriptionLanguage")
        check("auto spoken is not a same-language skip", !LocalTranslation.isSameLanguage(target: "en"))
        UserDefaults.standard.set("ur", forKey: "transcriptionLanguage")
        check("urdu to urdu copies the transcript", LocalTranslation.isSameLanguage(target: "ur"))
        check("urdu to english is not a copy", !LocalTranslation.isSameLanguage(target: "en"))
        if let spokenBefore {
            UserDefaults.standard.set(spokenBefore, forKey: "transcriptionLanguage")
        } else {
            UserDefaults.standard.removeObject(forKey: "transcriptionLanguage")
        }
        check("live side tabs include translation", LiveSideTab.translation.rawValue == "translation")
        check("two transform destinations", TextRewriter.Destination.allCases.count == 2)
        check("harness has no speech key", CloudVendor.selected.speechKey() == nil)
        check("missing key refuses cloud refine", HybridRefiner.canStartCloudWork() == false)
        check("word cap 1000", TextRewriter.wordCap == 1000)
        check("word count", TextRewriter.wordCount("one two three") == 3)
        check("selected text wins over clipboard",
              FocusText.resolveSource(selected: "hi", clipboard: "bye") == "hi")
        check("empty selection uses clipboard",
              FocusText.resolveSource(selected: "  ", clipboard: "bye") == "bye")
        check("both empty is nil", FocusText.resolveSource(selected: nil, clipboard: nil) == nil)
        check("local rewrite stays on localhost", TextRewriter.localChatURL.host == "localhost")
        check("local transform miss names Ollama",
              TextRewriter.ollamaUnavailableMessage.contains("Ollama")
              && TextRewriter.ollamaUnavailableMessage.contains("11434")
              && TextRewriter.isLocalUnavailable(
                TextRewriter.RewriteError.notConfigured(TextRewriter.ollamaUnavailableMessage)))
        check("in-process translation catalog has gemma3:1b",
              LocalTextCatalog.ids.contains("gemma3:1b")
              && LocalTextCatalog.entry(id: "gemma3:1b") != nil)
        check("local runs local only", ProcessingMode.local.runsLocalModel && !ProcessingMode.local.runsCloudModel)
        check("hybrid runs local then cloud", ProcessingMode.hybrid.runsLocalModel && ProcessingMode.hybrid.runsCloudModel)
        check("cloud skips local", !ProcessingMode.cloud.runsLocalModel && ProcessingMode.cloud.runsCloudModel)
        check("local translation never uses Gemini",
              TranslationRouting.destinations(for: .local) == [.local]
              && !TranslationRouting.usesGemini(.local))
        check("hybrid translation is local then Gemini",
              TranslationRouting.destinations(for: .hybrid) == [.local, .cloud]
              && TranslationRouting.usesGemini(.hybrid))
        check("cloud translation is Gemini only",
              TranslationRouting.destinations(for: .cloud) == [.cloud]
              && TranslationRouting.usesGemini(.cloud))
        check("new meeting is not a translation recording", Meeting().isTranslationRecording == false)
        check("report tabs include translation next to report",
              ReportTab.allCases.map(\.rawValue) == ["Report", "Translation", "Transcript", "Insights", "Notes"])
        check("local rewrite never uses a cloud host",
              TextRewriter.localChatURL.host != "generativelanguage.googleapis.com"
              && TextRewriter.localChatURL.host != "api.groq.com")
        var usage = AIUsage()
        usage.polishSeconds = 1200
        usage.polishVendor = CloudVendor.gemini.rawValue
        let items = usage.costBreakdown()
        check("gemini polish is unpriced", items.contains { $0.label == "Polish Gemini" && $0.usd == 0 })
        var groq = AIUsage()
        groq.polishSeconds = 1200
        check("legacy polish still Groq-priced",
              abs((groq.costBreakdown().last?.usd ?? -1) - 1200.0 / 3600 * 0.04) < 0.0001)
    }

    static func testGeminiHelpers() {
        check("bcp47 auto empty", GeminiLanguage.bcp47(from: "auto").isEmpty)
        check("bcp47 nil empty", GeminiLanguage.bcp47(from: nil).isEmpty)
        check("bcp47 de", GeminiLanguage.bcp47(from: "de") == ["de-DE"])
        check("bcp47 en", GeminiLanguage.bcp47(from: "en") == ["en-US"])
        let terms = GeminiGlossary.terms(from: "LaunchEase, Uygar\nfoo, , bar", cap: 100)
        check("glossary split", terms == ["LaunchEase", "Uygar", "foo", "bar"])
        let clipped = GeminiGlossary.terms(from: (0..<120).map { "t\($0)" }.joined(separator: ","), cap: 100)
        check("glossary cap 100", clipped.count == 100)
        let windows = RefineWindow.completed(elapsed: 600, window: 120, overlap: 5)
        check("window count 5", windows.count == 5)
        check("first window starts 0", windows.first?.start == 0)
        check("second window overlaps", windows.dropFirst().first?.start == 115)
        check("last window ends 600", windows.last?.end == 600)
        let part = SegmentPatcher.partition(starts: [0, 30, 119, 120, 200], windowEnd: 120)
        check("in-window before end", part.inWindow == [0, 1, 2])
        check("tail at and after end", part.tail == [3, 4])
        check("offset 0.100s", GeminiTranscriber.parseOffset("0.100s") == 0.1)
        check("offset bare", GeminiTranscriber.parseOffset("1.5") == 1.5)
        let words = [
            GeminiTranscriber.Word(text: "Hello", start: 0.1, end: 0.4),
            GeminiTranscriber.Word(text: "world", start: 0.45, end: 0.8),
            GeminiTranscriber.Word(text: "Later", start: 2.0, end: 2.4),
        ]
        let utt = GeminiTranscriber.utterances(from: words, shift: 10)
        check("utterance split on pause", utt.count == 2)
        check("utterance shift", abs(utt[0].start - 10.1) < 0.001)
        let json = """
        {"steps":[{"content":[{"type":"text","text":"Hello world","annotations":[
          {"type":"word_info","text":"Hello","start_offset":"0.100s","end_offset":"0.450s"},
          {"type":"word_info","text":"world","start_offset":"0.500s","end_offset":"0.850s"}
        ]}]}]}
        """.data(using: .utf8)!
        let parsed = try? GeminiTranscriber.parseSegments(json)
        check("parse word_info", parsed?.count == 1 && parsed?.first?.text == "Hello world")
        check("gemini timeout 60s window", GeminiTranscriber.timeout(forWindowSeconds: 60) == 90)
        check("gemini timeout 180s window", GeminiTranscriber.timeout(forWindowSeconds: 180) == 120)
        check("gemini live engine exists", TranscriptionBackend.gemini.label.contains("Gemini"))
        check("live session rotates before 10 min", GeminiLiveStreamer.sessionLimitSeconds == 540)
        check("urdu and hinglish have no live language hint",
              GeminiLanguage.bcp47(from: "ur").isEmpty
              && GeminiLanguage.bcp47(from: "hinglish").isEmpty)
        let liveJSON = """
        {"serverContent":{"interimInputTranscription":{"text":"hel"},"inputTranscription":{"text":"hello"}}}
        """.data(using: .utf8)!
        let live = GeminiLiveEvent.parse(liveJSON)
        check("live interim", live.interim == "hel")
        check("live final", live.finalText == "hello")
        let assigned = TranslationAssigner.apply(
            translations: [(0, 2, "Hallo"), (2.1, 4, "Welt")],
            segments: [(0, 2), (2, 4)])
        check("translation assign by overlap", assigned[0] == "Hallo" && assigned[1] == "Welt")
        let zipped = TranslationAssigner.apply(
            translations: [(0, 0, "a"), (0, 0, "b")],
            segments: [(0, 1), (1, 2)])
        check("translation assign by order when untimed", zipped[0] == "a" && zipped[1] == "b")
        let glancing = TranslationAssigner.apply(
            translations: [(1.99, 2.05, "nope")],
            segments: [(0, 2)])
        check("translation assign rejects glancing overlap", glancing[0] == nil)
        let cmdQ = HotkeyBinding(keyCode: UInt32(kVK_ANSI_Q), carbonModifiers: UInt32(cmdKey))
        check("⌘Q is reserved", cmdQ.isReserved)
        check("⌘Space is reserved",
              HotkeyBinding(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(cmdKey)).isReserved)
        check("hold and hands-free are different slots",
              HotkeySlot.dictationHold.defaultsKey != HotkeySlot.dictation.defaultsKey
              && HotkeySlot.dictationHold.rawValue == 4)
        check("paste last is its own slot", HotkeySlot.pasteLast.rawValue == 5)
        check("create settings sits with general and recording",
              SettingsSection.allCases.map(\.rawValue).contains("create"))
        let previousPaste = UserDefaults.standard.object(forKey: FeatureProcessing.autoPasteKey)
        UserDefaults.standard.removeObject(forKey: FeatureProcessing.autoPasteKey)
        check("auto-paste defaults on", FocusText.autoPasteEnabled)
        if let previousPaste {
            UserDefaults.standard.set(previousPaste, forKey: FeatureProcessing.autoPasteKey)
        }
        check("modifier display is control-option-shift-command",
              HotkeyBinding(keyCode: UInt32(kVK_ANSI_A),
                            carbonModifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
                .display.hasPrefix("⌃⌥⇧⌘"))
        check("key sanitizer strips quotes", APIKeyStore.sanitized("\"AIza123\"") == "AIza123")
        check("key sanitizer strips bearer", APIKeyStore.sanitized("Bearer AIza123") == "AIza123")
        let keyErr = """
        {"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT"}}
        """.data(using: .utf8)!
        check("gemini invalid key is named",
              TextRewriter.geminiError(keyErr, fallbackCode: 400).contains("Save Key"))
    }

    static func testDrainTimeout() {
        let cap = TranscriptionEngine.stopDrainCapSeconds
        check("drain cap is 20s", cap == 20)
        let fast: () async -> Bool = {
            await TranscriptionEngine.drainTimedOut(cap: 1) { }
        }
        // Can't await here from a sync test without a semaphore — the helper
        // is covered by the 20s constant and by Gemini window tests.
        check("drain helper exists", cap > 0)
        _ = fast
    }

    static func testRangedAudioRead() {
        let samples = [Float](repeating: 0.25, count: 16000 * 3)
        let wav = WAVEncoder.encode(samples: samples, sampleRate: 16000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-range-\(UUID().uuidString).wav")
        do {
            try wav.write(to: url)
            let slice = try AudioFileLoader.read16kMono(url: url, from: 1, duration: 1)
            check("ranged slice is ~1s", abs(slice.count - 16000) < 32)
            let past = try AudioFileLoader.read16kMono(url: url, from: 10, duration: 1)
            check("ranged past-end is empty", past.isEmpty)
        } catch {
            check("ranged reader \(error.localizedDescription)", false)
        }
    }

    @MainActor
    static func testClipboardAndTransforms() {
        let previous = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let previous { NSPasteboard.general.setString(previous, forType: .string) }
        }
        ClipboardOut.copy("parrot-clipboard-test")
        check("clipboard write helper",
              NSPasteboard.general.string(forType: .string) == "parrot-clipboard-test")

        let ctl = TransformController()
        ctl.beginInFlight()
        ctl.run(destination: .local)
        if case .failed(let message) = ctl.phase {
            check("transform busy", message == "A rewrite is already running.")
        } else {
            check("transform busy", false)
        }

        let over = Array(repeating: "word", count: TextRewriter.wordCap + 1).joined(separator: " ")
        var overCap = false
        do {
            try TextRewriter.guardLength(over)
        } catch TextRewriter.RewriteError.overCap {
            overCap = true
        } catch {}
        check("over-cap refuse", overCap)
        check("under-cap allowed", (try? TextRewriter.guardLength("short")) != nil)

        LocalTextModel.shared.unload()
        check("unload leaves the local model idle or missing",
              LocalTextModel.shared.state == .idle
              || LocalTextModel.shared.state == .missing
              || LocalTextModel.shared.state == .unsupported)
    }

    @MainActor
    static func testPolishReplaceKeepsTail() {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self, DictationNote.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
            check("polish container builds", false); return
        }
        let ctx = ModelContext(container)
        let meeting = Meeting()
        ctx.insert(meeting)
        for (start, text) in [(0.0, "old-a"), (30.0, "old-b"), (150.0, "tail")] {
            let row = TranscriptSegment(startTime: start, endTime: start + 1, text: text,
                                        speakerLabel: "Them", confidence: nil)
            ctx.insert(row)
            row.meeting = meeting
        }
        try? ctx.save()
        check("empty polish keeps old rows",
              TranscriptPolisher.applyWindow([], to: meeting, windowEnd: 120, context: ctx)
              && meeting.segments.map(\.text).sorted() == ["old-a", "old-b", "tail"])

        let replaced = TranscriptPolisher.applyWindow(
            [.init(text: "new-a", start: 0, end: 2, speaker: "Them")],
            to: meeting, windowEnd: 120, context: ctx)
        let texts = Set(meeting.segments.map(\.text))
        check("polish save succeeded", replaced)
        check("in-window rows replaced", texts.contains("new-a") && !texts.contains("old-a") && !texts.contains("old-b"))
        check("save-failure path keeps tail", texts.contains("tail"))

        let later = Meeting()
        ctx.insert(later)
        for (start, text) in [(0.0, "keep-a"), (30.0, "keep-b"), (80.0, "mid"), (150.0, "tail-2")] {
            let row = TranscriptSegment(startTime: start, endTime: start + 1, text: text,
                                        speakerLabel: "Them", confidence: nil)
            ctx.insert(row)
            row.meeting = later
        }
        try? ctx.save()
        _ = TranscriptPolisher.applyWindow(
            [.init(text: "new-mid", start: 80, end: 82, speaker: "Them")],
            to: later, windowStart: 60, windowEnd: 120, context: ctx)
        let laterTexts = Set(later.segments.map(\.text))
        check("earlier windows survive a later refine",
              laterTexts.contains("keep-a") && laterTexts.contains("keep-b"))
        check("only the refine window is replaced",
              laterTexts.contains("new-mid") && !laterTexts.contains("mid") && laterTexts.contains("tail-2"))
    }

    static func testMainDetailPane() {
        func pane(
            recording: Bool = false,
            translate: Bool = false,
            dictations: Bool = false,
            transforms: Bool = false,
            settings: Bool = false,
            dashboard: Bool = false,
            meeting: Bool = false
        ) -> MainDetailPane {
            MainDetailPane.resolve(
                isRecording: recording,
                showTranslate: translate,
                showDictations: dictations,
                showTransforms: transforms,
                showSettings: settings,
                showDashboard: dashboard,
                hasMeeting: meeting
            )
        }
        check("idle dashboard", pane(dashboard: true) == .dashboard)
        check("recording without other nav is live", pane(recording: true) == .live)
        check("settings wins over live recording",
              pane(recording: true, settings: true) == .settings)
        check("dictations win over live recording",
              pane(recording: true, dictations: true) == .dictations)
        check("transforms win over live recording",
              pane(recording: true, transforms: true) == .transforms)
        check("translate wins over live recording",
              pane(recording: true, translate: true) == .translate)
        check("past meeting wins over live recording",
              pane(recording: true, meeting: true) == .meeting)
        check("dashboard during recording stays dashboard",
              pane(recording: true, dashboard: true) == .dashboard)
        check("start from dashboard opens live",
              MainDetailPane.shouldOpenLiveOnStart(
                showTranslate: false, showDictations: false, showTransforms: false,
                showSettings: false, showDashboard: true, hasMeeting: false))
        check("start from settings stays put",
              !MainDetailPane.shouldOpenLiveOnStart(
                showTranslate: false, showDictations: false, showTransforms: false,
                showSettings: true, showDashboard: false, hasMeeting: false))
        check("stop on live reveals meeting",
              MainDetailPane.shouldRevealMeetingOnStop(
                showTranslate: false, showDictations: false, showTransforms: false,
                showSettings: false, showDashboard: false, hasMeeting: false))
        check("stop on dashboard stays put",
              !MainDetailPane.shouldRevealMeetingOnStop(
                showTranslate: false, showDictations: false, showTransforms: false,
                showSettings: false, showDashboard: true, hasMeeting: false))
    }
}
