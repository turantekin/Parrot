# Jev Fast Document Answers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the copilot's question-to-card delay with a free per-pace question floor, plus a TypeSafe "Jev" fast path that shows the answering knowledge-base excerpt within about half a second of the other side's question, in Claude mode only.

**Architecture:** The engine's `ingest` already knows "Them + looks like a question"; that is where the fast path forks off (a `Task` that searches the local KB at top 8, asks Jev one noul per chunk in a single HTTP call, and inserts a `doc_excerpt` card). The regular Haiku pass gets the chosen chunk pinned into its references and supersedes the excerpt when it produces a grounded card. A new `JevDocMatcher` class is the REST client (no protocol, one implementation). Three dev harnesses (`--kb-add`, `--doc-answer-eval`, `--copilot-replay`) provide the eval and the latency numbers.

**Tech Stack:** Swift 5.9+, SwiftUI, URLSession, NaturalLanguage (existing KB embedder), `make` / `swift build`, the `--profile-test` check harness.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-19-jev-fast-doc-answer-design.md`.
- Build with `make` / `make test`, never Xcode. `make test` must stay ALL PASS (235 checks today).
- Never log, print, or commit key material. The TypeSafe key lives only in the Keychain under account `typesafe-api-key`.
- The fast path exists only when: live provider is Claude, the TypeSafe key is present, and the profile has tagged documents. Otherwise nil, and behavior is byte-for-byte today's.
- Ollama and custom-server modes never call TypeSafe.
- Style through `Theme.swift`; no hardcoded colors or paddings in views.
- Plain English UI text, no jargon. No em dashes anywhere (house style).
- Dev harnesses live in `Parrot/CopilotHarness.swift` (new file), wired in `ParrotApp.swift`, documented in FILEMAP.md and CLAUDE.md.
- Real transcripts and the Launchese KB are private: eval fixtures under the session scratchpad `private/` folder, never in the repo. The repo only gets a small synthetic fixture.

---

## File map

| File | Change |
|---|---|
| `Parrot/Services/CallAnalysisEngine.swift` | question floor; `docMatcher`; `fastDocAnswer`; excerpt filters; Haiku handoff; `onInsightInserted` hook |
| `Parrot/Services/JevDocMatcher.swift` (new) | REST client, request builder, parser, usage meter, warm-up |
| `Parrot/Services/KnowledgeBaseService.swift` | `PARROT_KB_INDEX` env override for the store path |
| `Parrot/Models/Insight.swift` | `Insight.docExcerptKind` |
| `Parrot/Models/KindStyle.swift` | fallback style "From your docs" |
| `Parrot/Models/AIUsage.swift` | TypeSafe price, `docAnswers` bucket, cost line |
| `Parrot/Services/RecordingManager.swift` | owns the matcher, wires it, meters it, skips excerpts at persistence |
| `Parrot/Views/CopilotPanelView.swift` | hero clamps excerpt detail to 6 lines, tap to expand |
| `Parrot/Views/SettingsView.swift` | fourth key field; hint under Claude |
| `Parrot/CopilotHarness.swift` (new) | `--kb-add`, `--doc-answer-eval`, `--copilot-replay`, `StubAnalysisProvider` |
| `Parrot/ParrotApp.swift` | three flags |
| `Parrot/ProfileTest.swift` | new checks |
| `docs/help/privacy.html`, `docs/help/copilot-setup.html`, `README.md`, `FILEMAP.md`, `CLAUDE.md`, `docs/PERFORMANCE.md` | docs |

---

### Task 1: Per-pace question floor

**Files:**
- Modify: `Parrot/Services/CallAnalysisEngine.swift` (CopilotPace.timing ~L31-39, engine timing vars ~L120-124, `start` ~L131, `ingest` ~L186-215, `triggerAnalysis` ~L219-236)
- Test: `Parrot/ProfileTest.swift` (`testCopilotBudget` ~L773)

**Interfaces:**
- Produces: `CopilotPace.timing` gains `questionFloor: TimeInterval` as a fifth tuple element. Engine gains `private var pendingUrgent: Bool`.

- [ ] **Step 1: Write the failing checks** (append inside `testCopilotBudget`, before the window math):

```swift
        // Question floor: a "Them" question waits a short per-pace floor, never
        // the full one, and never longer on a quicker pace.
        check("fast question floor is 2s", CopilotPace.fast.timing.questionFloor == 2)
        check("balanced question floor is 5s", CopilotPace.balanced.timing.questionFloor == 5)
        check("relaxed question floor is 15s", CopilotPace.relaxed.timing.questionFloor == 15)
        for pace in CopilotPace.allCases {
            check("pace \(pace.rawValue) question floor never exceeds the floor",
                  pace.timing.questionFloor <= pace.timing.floor)
        }
        check("fast question debounce is 0.3s", CopilotPace.fast.timing.question == 0.3)
```

Also change the existing line `fast.question == 1 && fast.idle == 8 && fast.floor == 5 && fast.staleness == 15` to `fast.question == 0.3 && fast.idle == 8 && fast.floor == 5 && fast.staleness == 15` and rename that check to "pace fast keeps the original idle/floor/staleness".

- [ ] **Step 2: Run** `make test 2>&1 | tail -3` → expected: build error (`questionFloor` not a member).

- [ ] **Step 3: Implement.** In `CopilotPace`:

```swift
    /// (question fast-track debounce, idle debounce, floor between calls,
    /// staleness cap, question floor). Idle/floor/staleness on Fast are the
    /// original constants. The question floor is the shorter wait a "Them"
    /// question gets instead of the full floor: it keeps the single-in-flight
    /// rule and still caps calls per minute, which "bypass the floor" would not.
    var timing: (question: TimeInterval, idle: TimeInterval, floor: TimeInterval,
                 staleness: TimeInterval, questionFloor: TimeInterval) {
        switch self {
        case .fast: (0.3, 8, 5, 15, 2)
        case .balanced: (1, 15, 20, 45, 5)
        case .relaxed: (3, 30, 60, 120, 15)
        }
    }
```

In the engine: add `private var questionFloor: TimeInterval { CopilotPace.selected.timing.questionFloor }` next to the other timing vars, add `private var pendingUrgent = false` next to `rerunRequested`, reset it in `start()` (`pendingUrgent = false`). In `ingest`, right after `let isUrgent = ...`: `if isUrgent { pendingUrgent = true }`. In `triggerAnalysis`, replace `let wait = minimumInterval - ...` with:

```swift
        // A question waits the short question floor; the flag survives a
        // queued rerun so a question that lands mid-call keeps its fast lane.
        let floor = pendingUrgent ? questionFloor : minimumInterval
        pendingUrgent = false
        let wait = floor - Date.now.timeIntervalSince(lastAnalysisEnd)
```

Update the Settings caption for Fast in `CopilotPace.caption` only if it mentions numbers (it does not). Update `docs/PERFORMANCE.md` in Task 10.

- [ ] **Step 4: Run** `make test 2>&1 | tail -3` → ALL PASS, count 235 + 6.
- [ ] **Step 5: Commit** `git add -A Parrot/Services/CallAnalysisEngine.swift Parrot/ProfileTest.swift && git commit -m "Copilot: per-pace question floor so a question never waits the full floor"`.

---

### Task 2: JevDocMatcher client

**Files:**
- Create: `Parrot/Services/JevDocMatcher.swift`
- Test: `Parrot/ProfileTest.swift` (new `testJevMatcher`, register it in `run()` after `testCopilotBudget()`)

**Interfaces:**
- Produces:
  - `final class JevDocMatcher` with `static let model = "jev-latest"`, `static let keychainAccount = "typesafe-api-key"`, `static let maxCandidates = 8`, `static let budget: TimeInterval = 0.7`
  - `init(apiKey: String? = nil)` (override for harnesses; nil reads the Keychain)
  - `var isConfigured: Bool`
  - `static func buildBody(asked: String, before: String, candidates: [String]) -> [String: Any]`
  - `static func parse(_ data: Data, count: Int) throws -> [Double]`
  - `func score(asked: String, before: String, candidates: [String]) async throws -> [Double]`
  - `func warmUp()`
  - `var usageTotals: AITokenTotals`, `func resetUsage()`
  - `enum JevError: LocalizedError { case missingKey, badStatus(Int), badResponse }`

- [ ] **Step 1: Write the failing checks:**

```swift
    static func testJevMatcher() {
        typealias J = JevDocMatcher
        let body = J.buildBody(asked: "how much is express", before: "Them: hi",
                               candidates: ["Express £99", "Support hours"])
        check("jev body model", body["model"] as? String == "jev-latest")
        let state = body["state"] as? [String: String]
        check("jev state carries asked/before", state?["asked"] == "how much is express" && state?["before"] == "Them: hi")
        check("jev state names chunks c0..", state?["c0"] == "Express £99" && state?["c1"] == "Support hours")
        let questions = body["questions"] as? [String: [String: Any]]
        check("jev one noul per chunk", questions?.count == 2 && questions?["c1"]?["type"] as? String == "noul")
        check("jev instructions name the chunk", (questions?["c1"]?["instructions"] as? String)?.contains("`c1`") == true)
        // Serialized bytes must be stable across runs (sortedKeys) so the JSON is diffable.
        let a = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let b = try? JSONSerialization.data(withJSONObject: J.buildBody(asked: "how much is express", before: "Them: hi", candidates: ["Express £99", "Support hours"]), options: [.sortedKeys])
        check("jev body serializes deterministically", a != nil && a == b)

        let json = #"{"model":"jev-1.13.0","answers":{"c0":{"type":"noul","noul":0.98},"c1":{"type":"noul","noul":0.02}},"usage":{"input_tokens":598,"output_tokens":38}}"#
        let scores = try? J.parse(Data(json.utf8), count: 2)
        check("jev parse returns one score per chunk in order", scores == [0.98, 0.02])
        let short = try? J.parse(Data(#"{"answers":{"c0":{"type":"noul","noul":0.5}}}"#.utf8), count: 3)
        check("jev parse fills missing answers with 0", short == [0.5, 0, 0])
        check("jev parse rejects garbage", (try? J.parse(Data("nope".utf8), count: 1)) == nil)
        check("jev empty candidates builds no questions", (J.buildBody(asked: "x", before: "", candidates: [])["questions"] as? [String: Any])?.isEmpty == true)
        check("jev unconfigured without a key", !J(apiKey: "").isConfigured)
    }
```

- [ ] **Step 2: Run** `make test 2>&1 | tail -3` → build error (no `JevDocMatcher`).

- [ ] **Step 3: Implement** `Parrot/Services/JevDocMatcher.swift`:

```swift
import Foundation

enum JevError: LocalizedError {
    case missingKey
    case badStatus(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: "No TypeSafe API key set."
        case .badStatus(let code): "TypeSafe HTTP \(code)"
        case .badResponse: "TypeSafe returned an unreadable answer"
        }
    }
}

/// TypeSafe AI "Jev" client behind the copilot's fast document-answer path.
/// Jev never writes text: given the other side's question and up to eight
/// knowledge-base chunks, it returns one probability per chunk that the chunk
/// states what was asked. The engine shows the best chunk as a "From your
/// docs" excerpt while Haiku is still writing. Claude mode only; the path
/// exists only when a key is in the Keychain.
///
/// Verified 2026-09-19 against docs.typesafe.ai: POST /v1/systemone, Bearer
/// auth, `noul` answers carry no confidence field (the probability is the
/// gate), $0.042 per million input tokens, output free.
final class JevDocMatcher {
    static let model = "jev-latest"
    static let keychainAccount = "typesafe-api-key"
    static let maxCandidates = 8
    /// Whole round trip. Measured from this Mac 2026-09-19: 0.27–0.34 s on a
    /// warm connection, 0.61–0.74 s cold (TLS handshake) — hence warmUp().
    static let budget: TimeInterval = 0.7
    private let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private let apiKeyOverride: String?
    /// Own session so keep-alive connections stay ours and warm.
    private let session: URLSession

    init(apiKey: String? = nil) {
        apiKeyOverride = apiKey
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.budget
        config.timeoutIntervalForResource = Self.budget + 0.3
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config)
    }

    private var apiKey: String? {
        if let apiKeyOverride { return apiKeyOverride.isEmpty ? nil : apiKeyOverride }
        return APIKeyStore.load(account: Self.keychainAccount)?.nilIfEmpty
    }

    var isConfigured: Bool { apiKey != nil }

    // MARK: - Usage metering (same lock pattern as ClaudeAnalysisProvider)

    private let usageLock = NSLock()
    private var meteredUsage = AITokenTotals()

    var usageTotals: AITokenTotals {
        usageLock.lock(); defer { usageLock.unlock() }
        return meteredUsage
    }

    func resetUsage() {
        usageLock.lock(); defer { usageLock.unlock() }
        meteredUsage = AITokenTotals()
    }

    private func recordUsage(inputTokens: Int) {
        usageLock.lock(); defer { usageLock.unlock() }
        meteredUsage.inputTokens += inputTokens
        meteredUsage.calls += 1
    }

    // MARK: - Pure helpers (network-free, harness-tested)

    /// One request: JSON state with the question, a little context, and the
    /// chunks under c0…cN; one noul per chunk. Jev reads literally, so the
    /// instructions name the chunk key and tell it to ignore its siblings.
    static func buildBody(asked: String, before: String, candidates: [String]) -> [String: Any] {
        var state: [String: String] = ["asked": asked, "before": before]
        var questions: [String: [String: Any]] = [:]
        for (i, text) in candidates.prefix(maxCandidates).enumerated() {
            let key = "c\(i)"
            state[key] = text
            questions[key] = [
                "type": "noul",
                "instructions": "Does the text in `\(key)` state the information needed to directly answer the question in `asked`? Use `before` only to understand what `asked` refers to. Judge `\(key)` on its own; ignore the other c* texts.",
                "criteria": [
                    "true": "`\(key)` explicitly states the fact, number, price, policy, date, or procedure that `asked` is asking for.",
                    "false": "`\(key)` is only on a related topic, answers a different question, or gives no usable specifics.",
                ],
            ]
        }
        return ["model": model, "state": state, "questions": questions]
    }

    /// Probabilities by chunk index; a missing answer counts as 0.
    static func parse(_ data: Data, count: Int) throws -> [Double] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let answers = obj["answers"] as? [String: Any] else { throw JevError.badResponse }
        return (0..<count).map { i in
            ((answers["c\(i)"] as? [String: Any])?["noul"] as? Double) ?? 0
        }
    }

    private static func inputTokens(from data: Data) -> Int {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((obj?["usage"] as? [String: Any])?["input_tokens"] as? Int) ?? 0
    }

    // MARK: - Network

    func score(asked: String, before: String, candidates: [String]) async throws -> [Double] {
        guard let apiKey else { throw JevError.missingKey }
        let body = Self.buildBody(asked: asked, before: before, candidates: candidates)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.budget
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JevError.badResponse }
        guard http.statusCode == 200 else { throw JevError.badStatus(http.statusCode) }
        recordUsage(inputTokens: Self.inputTokens(from: data))
        return try Self.parse(data, count: min(candidates.count, Self.maxCandidates))
    }

    /// Opens the TLS connection ahead of the first real question so the first
    /// excerpt is not the one that pays the handshake. Fire-and-forget; the
    /// tiny request is metered like any other (about 60 tokens).
    func warmUp() {
        guard isConfigured else { return }
        Task { _ = try? await score(asked: "ready", before: "", candidates: ["ready"]) }
    }
}
```

- [ ] **Step 4: Run** `make test 2>&1 | tail -3` → ALL PASS, 12 new checks.
- [ ] **Step 5: Commit** `git add Parrot/Services/JevDocMatcher.swift Parrot/ProfileTest.swift && git commit -m "Jev: TypeSafe client for the fast document-answer path"`.

---

### Task 3: `--kb-add` harness and KB store override

**Files:**
- Modify: `Parrot/Services/KnowledgeBaseService.swift` (`storeURL` ~L217-224)
- Create: `Parrot/CopilotHarness.swift`
- Modify: `Parrot/ParrotApp.swift` (flag parsing)

**Interfaces:**
- Produces: `KnowledgeBaseService.storeURL` honors env `PARROT_KB_INDEX=<file>`; `KBAddTool.run(path: String)`.

- [ ] **Step 1: Store override.** Replace the body of `storeURL`:

```swift
    private static var storeURL: URL {
        // Dev harnesses point this at the sandboxed app's real index
        // (~/Library/Containers/com.uygar.parrot/…/KnowledgeBase/index.json)
        // so --kb-add / --doc-answer-eval work on what the app actually uses.
        if let override = ProcessInfo.processInfo.environment["PARROT_KB_INDEX"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parrot/KnowledgeBase", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.json")
    }
```

- [ ] **Step 2: Harness.** Create `Parrot/CopilotHarness.swift` with:

```swift
import Foundation
import SwiftUI

/// Dev-only: add a document to the knowledge base from the command line and
/// tag it into every built-in profile. Point PARROT_KB_INDEX at the sandboxed
/// app's index to change what the installed app uses; the previous index is
/// copied aside first.
///   PARROT_KB_INDEX=~/Library/Containers/com.uygar.parrot/Data/Library/Application\ Support/Parrot/KnowledgeBase/index.json \
///   .build/release/Parrot --kb-add ~/Downloads/file.md
@MainActor
enum KBAddTool {
    static func run(path: String) {
        Task { @MainActor in
            if let index = ProcessInfo.processInfo.environment["PARROT_KB_INDEX"],
               FileManager.default.fileExists(atPath: index) {
                let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
                let backup = (index as NSString).deletingPathExtension + "-backup-\(stamp).json"
                try? FileManager.default.copyItem(atPath: index, toPath: backup)
                print("kb-add: backed up index to \(backup)")
            }
            let kb = KnowledgeBaseService()
            let before = kb.documents.map(\.name)
            await kb.addDocuments(at: [URL(fileURLWithPath: path)])
            if let error = kb.lastError { print("kb-add FAILED: \(error)"); exit(1) }
            guard let doc = kb.documents.first(where: { $0.name == (path as NSString).lastPathComponent }) else {
                print("kb-add FAILED: document not indexed"); exit(1)
            }
            kb.setProfiles(Set(ProfilePresets.all().map(\.id)), for: doc)
            print("kb-add: \(doc.name) → \(doc.chunkCount) chunks, tagged into \(ProfilePresets.all().count) profiles (was: \(before))")
            exit(0)
        }
        dispatchMain()
    }
}
```

- [ ] **Step 3: Flag.** In `ParrotApp.swift` before `--profile-test`:

```swift
        if let i = args.firstIndex(of: "--kb-add"), i + 1 < args.count {
            MainActor.assumeIsolated { KBAddTool.run(path: args[i + 1]) }
            return
        }
```

- [ ] **Step 4: Run** `make build` then, against a COPY first: `cp "$KB" /tmp/kb-copy.json; PARROT_KB_INDEX=/tmp/kb-copy.json .build/release/Parrot --kb-add ~/Downloads/LAUNCHESE-COMPLETE-KNOWLEDGE-BASE.md` → prints chunk count (expect ~130). Then run against the real container index. Verify with `python3 -c 'import json; d=json.load(open(...)); print([(x["name"], x["chunkCount"], len(x["profileIDs"])) for x in d["documents"]])'`.
- [ ] **Step 5: Commit** `git add Parrot/CopilotHarness.swift Parrot/ParrotApp.swift Parrot/Services/KnowledgeBaseService.swift && git commit -m "Dev harness: --kb-add and PARROT_KB_INDEX override"`.

---

### Task 4: `--doc-answer-eval` harness

**Files:**
- Modify: `Parrot/CopilotHarness.swift`, `Parrot/ParrotApp.swift`

**Interfaces:**
- Consumes: `JevDocMatcher.score`, `KnowledgeBaseService.search(query:profileID:topK:)`.
- Produces: `DocAnswerEval.run(labelsPath: String, shape: String)` where labels JSON is `[{"asked": String, "before": String?, "expect": String?, "lang": String?}]`.

- [ ] **Step 1: Implement:**

```swift
/// Dev-only offline precision eval for the Jev fast path. Labels: a JSON list
/// of {asked, before?, expect?, lang?}; `expect` is a substring the answering
/// chunk must contain, null when the docs do not answer. Runs the real KB
/// search (PARROT_KB_INDEX) at top 8, asks Jev, and prints per-item verdicts
/// plus precision/recall at thresholds 0.50…0.90 and p50/p90 round trip.
///   .build/release/Parrot --doc-answer-eval labels.json [single|per-candidate]
/// The key is read through the `security` CLI so the unsigned dev binary never
/// triggers a Keychain consent dialog.
enum DocAnswerEval {
    struct Label: Decodable { let asked: String; let before: String?; let expect: String?; let lang: String? }
    struct Row { let label: Label; let refs: [KBReference]; let scores: [Double]; let seconds: Double; let expectedRank: Int? }

    static func run(labelsPath: String, shape: String) {
        Task { @MainActor in
            guard let data = FileManager.default.contents(atPath: labelsPath),
                  let labels = try? JSONDecoder().decode([Label].self, from: data) else {
                print("doc-answer-eval: cannot read labels"); exit(1)
            }
            let key = keychainKey()
            guard !key.isEmpty else { print("doc-answer-eval: no typesafe-api-key in Keychain"); exit(1) }
            let matcher = JevDocMatcher(apiKey: key)
            let kb = KnowledgeBaseService()
            print("doc-answer-eval: \(labels.count) labels, \(kb.documents.count) docs, shape=\(shape)")
            matcher.warmUp()
            try? await Task.sleep(for: .seconds(1))

            var rows: [Row] = []
            for label in labels {
                let refs = await kb.search(query: label.asked, profileID: nil, topK: JevDocMatcher.maxCandidates)
                let start = Date()
                var scores: [Double] = []
                do {
                    if shape == "per-candidate" {
                        scores = try await withThrowingTaskGroup(of: (Int, Double).self) { group in
                            for (i, ref) in refs.enumerated() {
                                group.addTask { (i, try await matcher.score(asked: label.asked, before: label.before ?? "", candidates: [ref.text]).first ?? 0) }
                            }
                            var out = Array(repeating: 0.0, count: refs.count)
                            for try await (i, p) in group { out[i] = p }
                            return out
                        }
                    } else if !refs.isEmpty {
                        scores = try await matcher.score(asked: label.asked, before: label.before ?? "", candidates: refs.map(\.text))
                    }
                } catch {
                    print("  ! \(label.asked): \(error.localizedDescription)")
                }
                let seconds = Date().timeIntervalSince(start)
                let rank = label.expect.flatMap { e in refs.firstIndex { $0.text.localizedCaseInsensitiveContains(e) } }
                rows.append(Row(label: label, refs: refs, scores: scores, seconds: seconds, expectedRank: rank))
                let best = scores.indices.max(by: { scores[$0] < scores[$1] })
                let bestText = best.map { refs[$0].text.replacingOccurrences(of: "\n", with: " ").prefix(70) } ?? ""
                print(String(format: "  p=%.2f rank=%@ %.2fs | %@ → %@",
                             best.map { scores[$0] } ?? 0, rank.map(String.init) ?? "-", seconds, label.asked, String(bestText)))
            }
            report(rows)
            exit(0)
        }
        dispatchMain()
    }

    static func report(_ rows: [Row]) {
        let covered = rows.filter { $0.label.expect != nil }
        print("\n=== retrieval (cosine top-8, question-only query) ===")
        print("expected chunk in top-1: \(covered.filter { $0.expectedRank == 0 }.count)/\(covered.count), top-4: \(covered.filter { ($0.expectedRank ?? 99) < 4 }.count), top-8: \(covered.filter { $0.expectedRank != nil }.count)")
        print("\n=== precision / recall by threshold ===")
        for t in stride(from: 0.50, through: 0.90, by: 0.05) {
            var hits = 0, shownWrong = 0, falsePos = 0
            for r in rows {
                guard let best = r.scores.indices.max(by: { r.scores[$0] < r.scores[$1] }), r.scores[best] >= t else { continue }
                if let e = r.label.expect {
                    if r.refs[best].text.localizedCaseInsensitiveContains(e) { hits += 1 } else { shownWrong += 1 }
                } else { falsePos += 1 }
            }
            let shown = hits + shownWrong + falsePos
            let precision = shown == 0 ? 0 : Double(hits) / Double(shown)
            let recall = covered.isEmpty ? 0 : Double(hits) / Double(covered.count)
            print(String(format: "t=%.2f shown=%2d hits=%2d wrong=%2d falsePos=%2d precision=%.2f recall=%.2f", t, shown, hits, shownWrong, falsePos, precision, recall))
        }
        for lang in Set(rows.compactMap { $0.label.lang }).sorted() {
            let sub = rows.filter { $0.label.lang == lang && $0.label.expect != nil }
            let hits = sub.filter { r in
                guard let b = r.scores.indices.max(by: { r.scores[$0] < r.scores[$1] }), r.scores[b] >= 0.75 else { return false }
                return r.refs[b].text.localizedCaseInsensitiveContains(r.label.expect!)
            }.count
            print("lang=\(lang): recall@0.75 = \(hits)/\(sub.count)")
        }
        let times = rows.map(\.seconds).sorted()
        if !times.isEmpty {
            print(String(format: "\nround trip p50=%.2fs p90=%.2fs max=%.2fs", times[times.count / 2], times[Int(Double(times.count - 1) * 0.9)], times.last!))
        }
    }

    /// Reads the key through /usr/bin/security (the item's trusted app), so the
    /// unsigned dev binary never blocks on a Keychain consent dialog.
    static func keychainKey() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "com.uygar.parrot", "-a", JevDocMatcher.keychainAccount, "-w"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

Flag in `ParrotApp.swift`: `--doc-answer-eval <labels> [shape]` → `DocAnswerEval.run(labelsPath:shape:)` (default shape "single").

- [ ] **Step 2: Fixtures.** Write `scratchpad/private/labels.json` (about 45 English, 15 Turkish, 12 uncovered, from the Launchese KB plus real questions from meetings 60/63/88/94/97). Commit only a 6-item synthetic fixture at `docs/superpowers/fixtures/doc-answer-labels.example.json` that uses the repo's own help text? No: the eval needs the KB; keep the fixture out of the repo and document the format in the harness comment instead.
- [ ] **Step 3: Run both shapes** against the real index: `PARROT_KB_INDEX=... .build/release/Parrot --doc-answer-eval scratchpad/private/labels.json single` and `... per-candidate`. Record: precision/recall table, per-language recall, latency, retrieval ranks. Choose the threshold (lowest t with precision ≥ 0.90; never below 0.60) and the shape. Set `CallAnalysisEngine.docAnswerThreshold` in Task 5 accordingly. If Turkish recall@threshold is under 0.5 with acceptable precision, still ship it (the gate is precision, not recall); if Turkish precision is under 0.85, add the English-only gate in Task 5.
- [ ] **Step 4: Commit** `git add Parrot/CopilotHarness.swift Parrot/ParrotApp.swift && git commit -m "Dev harness: --doc-answer-eval precision/recall/latency for the Jev path"`.

---

### Task 5: Engine fast path, card, and Haiku handoff

**Files:**
- Modify: `Parrot/Models/Insight.swift`, `Parrot/Models/KindStyle.swift`, `Parrot/Services/CallAnalysisEngine.swift`, `Parrot/Services/RecordingManager.swift` (init ~L56, persistence ~L277, `startRecording` ~L231)
- Test: `Parrot/ProfileTest.swift` (`testDocExcerpt`, register after `testJevMatcher`)

**Interfaces:**
- Produces: `Insight.docExcerptKind = "doc_excerpt"`; engine `var docMatcher: JevDocMatcher?`, `static var docAnswerThreshold: Double`, `static func bestCandidate(scores:threshold:) -> (index: Int, probability: Double)?`, `static func excerptTitle(for:) -> String`, `static func excerptSuperseded(question:document:by:) -> Bool`, `var onInsightInserted: ((Insight) -> Void)?`, `private(set) var fastPathStats: (attempts: Int, hits: Int, failures: Int)`.

- [ ] **Step 1: Failing checks:**

```swift
    static func testDocExcerpt() {
        typealias E = CallAnalysisEngine
        check("excerpt kind is reserved", Insight.docExcerptKind == "doc_excerpt")
        let style = KindResolver.fallbackStyle(forKey: Insight.docExcerptKind)
        check("excerpt style label", style.label == "From your docs")
        check("excerpt style not pinned", !style.isPinned)
        check("best candidate picks the max over threshold", E.bestCandidate(scores: [0.1, 0.9, 0.4], threshold: 0.75)?.index == 1)
        check("best candidate nil under threshold", E.bestCandidate(scores: [0.1, 0.6], threshold: 0.75) == nil)
        check("best candidate nil on empty", E.bestCandidate(scores: [], threshold: 0.5) == nil)
        check("excerpt title quotes and capitalizes", E.excerptTitle(for: "  how much is express verification ") == "“How much is express verification”")
        let long = String(repeating: "word ", count: 40)
        check("excerpt title truncates at a word", E.excerptTitle(for: long).count <= 96 && E.excerptTitle(for: long).hasSuffix("…”"))
        let cite = InsightDraft(kindKey: "suggestion", title: "Answer the pricing question", detail: "x", source: "pricing.md", reply: "It is £99.")
        let stem = InsightDraft(kindKey: "suggestion", title: "Express verification costs £99", detail: "Say the price.", source: nil, reply: "Express is £99, same working day.")
        let unrelated = InsightDraft(kindKey: "buying_signal", title: "Wants to start next week", detail: "Timeline signal", source: nil, reply: nil)
        let stemNoReply = InsightDraft(kindKey: "question", title: "Express verification timing unclear", detail: "y", source: nil, reply: nil)
        check("superseded by a card citing the same document", E.excerptSuperseded(question: "how much is express verification", document: "Pricing.MD", by: [cite]))
        check("superseded by an answer sharing a topic stem", E.excerptSuperseded(question: "how much is express verification", document: "pricing.md", by: [stem]))
        check("not superseded by an unrelated card", !E.excerptSuperseded(question: "how much is express verification", document: "pricing.md", by: [unrelated]))
        check("not superseded by a stem match without a reply", !E.excerptSuperseded(question: "how much is express verification", document: "pricing.md", by: [stemNoReply]))
        check("not superseded by nothing", !E.excerptSuperseded(question: "q", document: "d", by: []))
    }
```

- [ ] **Step 2: Run** → build errors.

- [ ] **Step 3: Implement.**

`Insight.swift`: inside `struct Insight` add `/// Reserved kind for the Jev fast path's "From your docs" excerpt card. Never a profile kind; filtered out of Haiku's known list, dedup, and persistence.` `static let docExcerptKind = "doc_excerpt"`.

`KindStyle.swift` `fallbackStyle`: add before `default:`
```swift
        case Insight.docExcerptKind:
            return KindStyle(label: "From your docs", color: Theme.Colors.ink2, iconSystemName: "doc.text.magnifyingglass", isPinned: false)
```

`CallAnalysisEngine.swift` additions:

```swift
    // MARK: - Fast document answers (Jev)

    /// Set by RecordingManager. nil means the path does not exist for this call.
    var docMatcher: JevDocMatcher?
    /// Best-noul gate for showing an excerpt. Tuned by --doc-answer-eval
    /// (2026-09-19 run: see docs/PERFORMANCE.md). Precision first.
    nonisolated static var docAnswerThreshold = 0.75
    /// Dev harness observation hook (--copilot-replay): every insertion, wall time.
    var onInsightInserted: ((Insight) -> Void)?
    private(set) var fastPathStats: (attempts: Int, hits: Int, failures: Int) = (0, 0, 0)
    private var fastTask: Task<Void, Never>?
    private var consecutiveFastFailures = 0
    /// Excerpts shown since the last Haiku pass: their chunk is pinned into
    /// Haiku's references, and a grounded Haiku card supersedes them.
    private var pendingExcerpts: [(id: UUID, chunk: KBReference, question: String)] = []

    private var fastPathAvailable: Bool {
        docMatcher?.isConfigured == true
            && CopilotProviderKind.selected == .claude
            && knowledgeBase.map { !$0.isEmpty } == true
            && consecutiveFastFailures < 3
    }
```

In `start()`: `fastTask?.cancel(); fastTask = nil; pendingExcerpts = []; consecutiveFastFailures = 0; fastPathStats = (0, 0, 0)` and at the end `if fastPathAvailable { docMatcher?.warmUp() }`. In `stop()`: `fastTask?.cancel(); fastTask = nil; pendingExcerpts = []`.

In `ingest`, after `if isUrgent { pendingUrgent = true }`:

```swift
        if isUrgent, fastPathAvailable {
            // Fork the Jev fast path here, before any debounce: this is the one
            // place that sees "Them + question" first. It never touches the
            // Haiku cadence. The previous one or two lines disambiguate
            // follow-ups ("and for express?").
            let before = segments.dropLast().suffix(2)
                .map { "\($0.source.label): \($0.text)" }.joined(separator: "\n")
            fastTask?.cancel()
            fastTask = Task { [weak self] in
                await self?.fastDocAnswer(question: text, before: before, at: time)
            }
        }
```

New method:

```swift
    private func fastDocAnswer(question: String, before: String, at time: TimeInterval) async {
        guard let matcher = docMatcher, let kb = knowledgeBase else { return }
        fastPathStats.attempts += 1
        let refs = await kb.search(query: question, profileID: activeProfile?.id,
                                   topK: JevDocMatcher.maxCandidates)
        guard !refs.isEmpty, isActive, !Task.isCancelled else { return }
        do {
            let scores = try await matcher.score(asked: question, before: before,
                                                 candidates: refs.map(\.text))
            guard isActive, !Task.isCancelled else { return }
            consecutiveFastFailures = 0
            guard let best = Self.bestCandidate(scores: scores, threshold: Self.docAnswerThreshold) else { return }
            let chunk = refs[best.index]
            let card = Insight(kindKey: Insight.docExcerptKind, title: Self.excerptTitle(for: question),
                               detail: chunk.text, callTime: time, source: chunk.documentName)
            insights.insert(card, at: 0)
            pendingExcerpts.append((card.id, chunk, question))
            fastPathStats.hits += 1
            onInsightInserted?(card)
        } catch {
            // Silent by design: Haiku is still coming. Three in a row switch
            // the path off for the rest of the call (see fastPathAvailable).
            consecutiveFastFailures += 1
            fastPathStats.failures += 1
        }
    }

    nonisolated static func bestCandidate(scores: [Double], threshold: Double) -> (index: Int, probability: Double)? {
        guard let i = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[i] >= threshold else { return nil }
        return (i, scores[i])
    }

    /// The question as heard, quoted and capitalized, cut at a word under ~90 chars.
    nonisolated static func excerptTitle(for question: String) -> String {
        var q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = q.first { q = first.uppercased() + q.dropFirst() }
        if q.count > 90 {
            let cut = q.prefix(88)
            q = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        return "“\(q)”"
    }

    /// A Haiku card supersedes an excerpt when it cites the same document, or
    /// when it is an answer (carries a reply) about the same topic.
    nonisolated static func excerptSuperseded(question: String, document: String, by drafts: [InsightDraft]) -> Bool {
        drafts.contains { d in
            if let s = d.source, s.lowercased() == document.lowercased() { return true }
            return d.reply?.nilIfEmpty != nil && sharesTopicStem(question, "\(d.title) \(d.detail)")
        }
    }
```

In `runAnalysis`:
- `let knownTitles = insights.filter { $0.kindKey != Insight.docExcerptKind }.prefix(20).map(\.title)`
- after the KB search: `var references = ...; for p in pendingExcerpts.reversed() where !references.contains(where: { $0.text == p.chunk.text }) { references.insert(p.chunk, at: 0) }` and pass `references` into the request.
- after `let result = try await provider.analyze(request)` and the isActive guard, before `sentiment = merged`:
```swift
            // Excerpts shown since the last pass: a grounded Haiku card on the
            // same question replaces them; otherwise they stay (still true).
            let shownExcerpts = pendingExcerpts
            pendingExcerpts = []
            for p in shownExcerpts where Self.excerptSuperseded(question: p.question, document: p.chunk.documentName, by: result.insights) {
                insights.removeAll { $0.id == p.id }
            }
```
- `let openInsights = insights.filter { !$0.isHandled && $0.kindKey != Insight.docExcerptKind }`
- after `insights.insert(contentsOf: unique, at: 0)`: `for u in unique { onInsightInserted?(u) }`

In `dismiss(_:)`: add `pendingExcerpts.removeAll { $0.id == insight.id }`.

`RecordingManager.swift`: add `let docMatcher = JevDocMatcher()` next to `knowledgeBase`; in `init()` add `callAnalysisEngine.docMatcher = docMatcher`; in `startRecording` next to `callAnalysisEngine.provider.resetUsage()` add `docMatcher.resetUsage()`; in the persistence loop use `for insight in callAnalysisEngine.insights where insight.kindKey != Insight.docExcerptKind {`.

- [ ] **Step 4: Run** `make test` → ALL PASS.
- [ ] **Step 5: Commit** `git commit -am "Copilot: Jev fast path shows the answering document excerpt within a second"`.

---

### Task 6: Panel, Settings, and cost row

**Files:**
- Modify: `Parrot/Views/CopilotPanelView.swift` (HeroInsightCard ~L447-545), `Parrot/Views/SettingsView.swift` (apiKeysPage ~L556, providerConfig(.claude) ~L462), `Parrot/Models/AIUsage.swift`, `Parrot/Services/RecordingManager.swift` (`writeAIUsage` ~L585)
- Test: `Parrot/ProfileTest.swift` (`testAIUsageCost`)

- [ ] **Step 1: Failing check** (append to `testAIUsageCost`):

```swift
        var withDocs = AIUsage()
        withDocs.copilotModel = "claude-haiku-4-5"
        withDocs.copilot = AITokenTotals(inputTokens: 1000, outputTokens: 100, calls: 1)
        withDocs.docAnswerModel = JevDocMatcher.model
        withDocs.docAnswers = AITokenTotals(inputTokens: 1_000_000, outputTokens: 0, calls: 300)
        let docLine = withDocs.costBreakdown().first { $0.label.hasPrefix("Doc answers") }
        check("doc answers line exists when calls > 0", docLine != nil)
        check("doc answers priced at $0.042 per MTok input", docLine.map { abs($0.usd - 0.042) < 0.0001 } == true)
        check("doc answers line names the model and calls", docLine?.label.contains("jev-latest") == true && docLine?.detail.contains("300 calls") == true)
        check("no doc answers line without calls", usage.costBreakdown().contains { $0.label.hasPrefix("Doc answers") } == false)
        let encoded = try? JSONEncoder().encode(withDocs)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(AIUsage.self, from: $0) }
        check("doc answers round-trip", decoded?.docAnswers?.calls == 300)
        let legacy = try? JSONDecoder().decode(AIUsage.self, from: Data(#"{"copilotModel":"m","copilot":{"inputTokens":1,"outputTokens":1,"calls":1},"transcriptionBackend":"local","transcriptionSeconds":1,"transcriptionTracks":2,"polishSeconds":0}"#.utf8))
        check("legacy usage decodes without doc answers", legacy != nil && legacy?.docAnswers == nil)
```

- [ ] **Step 2: Implement.**

`AIUsage.swift`: in `AIPricing` add `/// TypeSafe jev-latest: $0.042 per 1M input tokens, output free (docs.typesafe.ai/models, 2026-09-19).` `static let typesafeInputUSDPerMTok = 0.042`. In `AIUsage` add after `reports`: `/// Jev fast document answers (Claude mode + TypeSafe key). nil on older meetings and when the path never ran.` `var docAnswerModel: String?` and `var docAnswers: AITokenTotals?`. In `costBreakdown()` after the reports block:

```swift
        if let docAnswers, docAnswers.calls > 0 {
            items.append(LineItem(
                label: "Doc answers \(docAnswerModel ?? "")",
                detail: "\(docAnswers.calls) calls · \(Self.compactTokens(docAnswers.inputTokens)) in",
                usd: Double(docAnswers.inputTokens) / 1_000_000 * AIPricing.typesafeInputUSDPerMTok))
        }
```

`RecordingManager.writeAIUsage`, before `usage.transcriptionBackend = ...`:
```swift
        let docTotals = docMatcher.usageTotals
        if docTotals.calls > 0 {
            usage.docAnswerModel = JevDocMatcher.model
            usage.docAnswers = docTotals
        }
```

`SettingsView.apiKeysPage`, after the Deepgram section:
```swift
            Section("TypeSafe — instant answers from your documents") {
                ProviderKeyField(
                    label: "TypeSafe API key",
                    account: JevDocMatcher.keychainAccount,
                    placeholder: "apikey_…",
                    hint: "When the other side asks a question, the question, a few lines of context and the matching snippets of your documents go to TypeSafe AI (hosted in the US) so the matching excerpt can show within a second. Audio never. Claude mode only. Keys: typesafe.ai"
                )
            }
```
`providerConfig(for: .claude)`: add a second `HStack` with `Hint("Add a TypeSafe key to show matching excerpts from your documents within a second of a question.")` and the same "Open API Keys" link.

`CopilotPanelView.HeroInsightCard`: add `@State private var showsWholeExcerpt = false` and `private var isExcerpt: Bool { insight.kindKey == Insight.docExcerptKind }`; on the detail `Text` add `.lineLimit(isExcerpt && !showsWholeExcerpt ? 6 : nil)` and after it, when `isExcerpt`, a small button: `Button(showsWholeExcerpt ? "Show less" : "Show more") { withAnimation(.easeOut(duration: 0.15)) { showsWholeExcerpt.toggle() } }.buttonStyle(.plain).font(Theme.Typography.sans(11, .medium)).foregroundStyle(Theme.Colors.accent)` shown only when `insight.detail.count > 240`.

- [ ] **Step 3: Run** `make test` → ALL PASS. Run `.build/release/Parrot --copilot-snapshot /tmp/copilot.png` and eyeball the hero after temporarily seeding an excerpt (add an excerpt Insight as index 0 in `CopilotSnapshot.write`'s list permanently: `Insight(kindKey: Insight.docExcerptKind, title: "“How much is the express verification”", detail: "Identity verification: £50 Standard (within one week), £99 Express (same working day); free if the person does it themselves at GOV.UK.", callTime: 760, source: "pricing.md")`) and check the rendered PNG.
- [ ] **Step 4: Commit** `git commit -am "Copilot: From-your-docs card, TypeSafe key field, doc-answers cost line"`.

---

### Task 7: `--copilot-replay` harness

**Files:**
- Modify: `Parrot/CopilotHarness.swift`, `Parrot/ParrotApp.swift`

**Interfaces:**
- Consumes: `CallAnalysisEngine.ingest`, `onInsightInserted`, `fastPathStats`, `docMatcher`; `CopilotPace` via `UserDefaults.register(defaults:)`.
- Produces: `CopilotReplay.run(transcriptPath: String, args: [String])`; `final class StubAnalysisProvider: AnalysisProvider`.

- [ ] **Step 1: Implement:**

```swift
/// Dev-only: fixed-latency stand-in for Haiku so replay timing is deterministic.
/// Emits one "suggestion" per pass about the newest "Them" question in the
/// window, so the Haiku path produces a measurable first card.
final class StubAnalysisProvider: AnalysisProvider {
    let latency: TimeInterval
    private let lock = NSLock()
    private var totals = AITokenTotals()
    init(latency: TimeInterval) { self.latency = latency }
    var isConfigured: Bool { true }
    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult {
        try await Task.sleep(for: .seconds(latency))
        lock.lock(); totals.calls += 1; totals.inputTokens += 900; totals.outputTokens += 250; lock.unlock()
        let lastQuestion = request.transcript.split(separator: "\n").last { $0.hasPrefix("Them:") && CallAnalysisEngine.looksLikeQuestion(String($0)) }
        let drafts = lastQuestion.map { [InsightDraft(kindKey: "suggestion", title: "Stub answer: \($0.dropFirst(6).prefix(60))", detail: "stub", source: nil, reply: "stub reply")] } ?? []
        return AnalysisResult(insights: drafts, sentiment: ["score": 50], read: "stub", coach: nil, resolved: [])
    }
    func summarize(transcript: String, insightTitles: [String], instructions: String, counterpart: String) async throws -> String { "" }
    func coachingReport(transcript: String, talkPercentMe: Int, instructions: String, counterpart: String) async throws -> String { "" }
    var usageTotals: AITokenTotals { lock.lock(); defer { lock.unlock() }; return totals }
    func resetUsage() { lock.lock(); totals = AITokenTotals(); lock.unlock() }
}

/// Dev-only latency replay. Feeds a transcript export (`[mm:ss] Label: text`)
/// into the real engine at real time and logs, per "Them" question, the wall
/// delay to the first card and which path produced it.
///   .build/release/Parrot --copilot-replay export.txt [--pace fast] [--haiku-ms 2500] [--fast on|off] [--limit-seconds 600]
@MainActor
enum CopilotReplay {
    struct Line { let time: TimeInterval; let source: AudioSource; let text: String }

    static func parse(_ text: String) -> [Line] {
        text.split(separator: "\n").compactMap { raw in
            guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { return nil }
            let stamp = raw[raw.index(after: raw.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let m = Int(stamp[0]), let s = Int(stamp[1]) else { return nil }
            let rest = raw[raw.index(after: close)...].drop(while: { $0 == " " })
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            let label = rest[..<colon]
            let body = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return nil }
            return Line(time: TimeInterval(m * 60 + s), source: label == "Me" ? .me : .them, text: body)
        }
    }

    static func run(transcriptPath: String, args: [String]) {
        func opt(_ name: String, _ def: String) -> String {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return def }
            return args[i + 1]
        }
        let pace = opt("--pace", "fast"), haikuMs = Double(opt("--haiku-ms", "2500")) ?? 2500
        let fastOn = opt("--fast", "on") == "on", limit = Double(opt("--limit-seconds", "600")) ?? 600
        UserDefaults.standard.register(defaults: ["copilotPace": pace, "copilotEnabled": true, "copilotProvider": "claude", "copilotWindow": "standard"])
        Task { @MainActor in
            guard let text = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else { print("copilot-replay: cannot read transcript"); exit(1) }
            let lines = parse(text).filter { $0.time <= limit }
            let engine = CallAnalysisEngine(provider: StubAnalysisProvider(latency: haikuMs / 1000))
            engine.knowledgeBase = KnowledgeBaseService()
            if fastOn { engine.docMatcher = JevDocMatcher(apiKey: DocAnswerEval.keychainKey()) }
            let profile = ProfilePresets.all().first { $0.name == "Sales discovery" }
            print("copilot-replay: \(lines.count) lines, pace=\(pace), haiku=\(Int(haikuMs))ms, fast=\(fastOn), kb docs=\(engine.knowledgeBase?.documents.count ?? 0)")

            var pendingQuestions: [(text: String, at: Date)] = []
            var results: [(question: String, seconds: Double, path: String)] = []
            engine.onInsightInserted = { insight in
                guard let q = pendingQuestions.first else { return }
                let path = insight.kindKey == Insight.docExcerptKind ? "excerpt" : "haiku"
                results.append((q.text, Date().timeIntervalSince(q.at), path))
                pendingQuestions.removeFirst()
                print(String(format: "  %5.2fs %-7@ ← %@", Date().timeIntervalSince(q.at), path, q.text.prefix(60)))
            }
            engine.start(profile: profile)
            let t0 = Date()
            for line in lines {
                let due = t0.addingTimeInterval(line.time)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if line.source == .them, CallAnalysisEngine.looksLikeQuestion(line.text) {
                    pendingQuestions.append((line.text, Date()))
                }
                engine.ingest(text: line.text, at: line.time, source: line.source)
            }
            try? await Task.sleep(for: .seconds(max(8, haikuMs / 1000 + 6)))
            engine.stop()
            let minutes = max(1, (lines.last?.time ?? 60) / 60)
            report(results, calls: engine.provider.usageTotals.calls, minutes: minutes, stats: engine.fastPathStats, unanswered: pendingQuestions.count)
            exit(0)
        }
        dispatchMain()
    }

    static func report(_ results: [(question: String, seconds: Double, path: String)], calls: Int, minutes: Double, stats: (attempts: Int, hits: Int, failures: Int), unanswered: Int) {
        func pct(_ xs: [Double], _ p: Double) -> Double { let s = xs.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))] }
        print("\n=== copilot-replay ===")
        for path in ["excerpt", "haiku"] {
            let xs = results.filter { $0.path == path }.map(\.seconds)
            print(String(format: "%-7@ n=%2d median=%.2fs p90=%.2fs max=%.2fs", path, xs.count, pct(xs, 0.5), pct(xs, 0.9), xs.max() ?? 0))
        }
        let all = results.map(\.seconds)
        print(String(format: "all     n=%2d median=%.2fs p90=%.2fs  unanswered=%d", all.count, pct(all, 0.5), pct(all, 0.9), unanswered))
        print(String(format: "haiku calls=%d (%.1f/min)  fast attempts=%d hits=%d failures=%d", calls, Double(calls) / minutes, stats.attempts, stats.hits, stats.failures))
    }
}
```

Flag: `--copilot-replay <path> [options...]` → `CopilotReplay.run(transcriptPath:args:)`.

- [ ] **Step 2: Fixture.** Build `scratchpad/private/replay-launchese.txt` from a real English Launchese call (meeting 60 or 63 export) with a few synthesized doc-covered questions spliced in at natural points, 10 minutes. Also `docs/superpowers/fixtures/replay-example.txt`: a 3-minute synthetic call using the analyze-test fixture style (repo-safe).
- [ ] **Step 3: Run** for each pace, fast on and off (six runs of up to 10 minutes each; run in the background). Record the table for `docs/PERFORMANCE.md`.
- [ ] **Step 4: Commit** `git commit -am "Dev harness: --copilot-replay question-to-card latency with and without the Jev path"`.

---

### Task 8: Docs

**Files:** `docs/help/privacy.html`, `docs/help/copilot-setup.html`, `README.md` (lines ~51, ~78, cost table ~144), `FILEMAP.md`, `CLAUDE.md` (harness list), `docs/PERFORMANCE.md`, the spec (status → implemented, numbers).

- [ ] Add the privacy bullet, the setup paragraph, the README vendor mention and a cost-table row ("Doc answers (TypeSafe) | under $0.02/hr | matching excerpt within a second of a question"), FILEMAP rows for the two new files and refreshed line counts, CLAUDE.md harness flags (`--kb-add`, `--doc-answer-eval`, `--copilot-replay`), PERFORMANCE.md section "Test 5 — Question floor + Jev fast path (2026-09-19)" with the eval and replay tables.
- [ ] Commit `git commit -am "Docs: Jev fast path, privacy and setup pages, performance numbers"`.

---

### Task 9: Install and hand over

- [ ] `make test` ALL PASS; `.build/release/Parrot --analyze-test claude` succeeds (Haiku still fine, schema unchanged so no grammar recompile).
- [ ] `SKIP_NOTARIZE=1 scripts/release.sh 0.18.0-dev` (Developer ID signing so TCC grants persist), confirm Parrot is not running, `rm -rf /Applications/Parrot.app && ditto dist/Parrot.app /Applications/Parrot.app`, `spctl -a`, then `security add-generic-password -U -T /Applications/Parrot.app -s com.uygar.parrot -a typesafe-api-key -w "$(security find-generic-password -s com.uygar.parrot -a typesafe-api-key -w)"` so the installed app can read the key without a consent dialog, then `open /Applications/Parrot.app`.
- [ ] Verify in the running app: Settings → Knowledge lists the Launchese document with its chunk count; Settings → API Keys shows the TypeSafe field as saved; a `say`-driven test recording with a Launchese question produces the excerpt card (drive with the mic-grab recipe from memory only if the user is not using the machine; otherwise leave to the user).
