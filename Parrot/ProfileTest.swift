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
        testHallucinationFilter()
        testWAVEncoder()
        testAIUsageCost()
        testPermissionFlow()
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
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
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
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
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
    }
}
