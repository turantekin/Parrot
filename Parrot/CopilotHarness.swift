import Foundation
import SwiftUI

// Dev-only copilot harnesses. None of these run in a normal launch; ParrotApp
// dispatches them from CLI flags. They exist so the Jev fast path and the
// question-floor change have numbers behind them (docs/PERFORMANCE.md).

// MARK: - --kb-add

/// Adds a document to the knowledge base from the command line and tags it
/// into every built-in profile. Point PARROT_KB_INDEX at the sandboxed app's
/// index to change what the installed app uses; the previous index is copied
/// aside first.
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
            let profiles = ProfilePresets.all()
            kb.setProfiles(Set(profiles.map(\.id)), for: doc)
            print("kb-add: \(doc.name) → \(doc.chunkCount) chunks, tagged into \(profiles.count) profiles (already there: \(before))")
            exit(0)
        }
        dispatchMain()
    }
}

// MARK: - --doc-answer-eval

/// Offline precision eval for the Jev fast path. Labels: a JSON list of
/// {asked, before?, expect?, lang?}; `expect` is a substring the answering
/// chunk must contain, null when the docs do not answer. Runs the real KB
/// search (PARROT_KB_INDEX) at top 8, asks Jev, and prints per-item verdicts
/// plus precision/recall at thresholds 0.50…0.90 and p50/p90 round trip.
///   .build/release/Parrot --doc-answer-eval labels.json [single|per-candidate]
/// The key is read through the `security` CLI so the unsigned dev binary never
/// triggers a Keychain consent dialog.
enum DocAnswerEval {
    struct EvalLabel: Decodable {
        let asked: String
        let before: String?
        let expect: String?
        let lang: String?
    }

    struct Row {
        let label: EvalLabel
        let refs: [KBReference]
        let scores: [Double]
        let seconds: Double
        /// Cosine rank (0-based, within the top 8) of the first chunk containing `expect`.
        let expectedRank: Int?

        var best: Int? { scores.indices.max(by: { scores[$0] < scores[$1] }) }
        func hit(at threshold: Double) -> Bool? {
            guard let best, scores[best] >= threshold else { return nil }
            guard let expect = label.expect else { return false }
            return refs[best].text.localizedCaseInsensitiveContains(expect)
        }
    }

    static func run(labelsPath: String, shape: String) {
        Task { @MainActor in
            guard let data = FileManager.default.contents(atPath: labelsPath),
                  let labels = try? JSONDecoder().decode([EvalLabel].self, from: data) else {
                print("doc-answer-eval: cannot read labels at \(labelsPath)"); exit(1)
            }
            let key = keychainKey()
            guard !key.isEmpty else { print("doc-answer-eval: no typesafe-api-key in the Keychain"); exit(1) }
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
                                group.addTask {
                                    (i, try await matcher.score(asked: label.asked, before: label.before ?? "",
                                                                candidates: [ref.text]).first ?? 0)
                                }
                            }
                            var out = Array(repeating: 0.0, count: refs.count)
                            for try await (i, p) in group { out[i] = p }
                            return out
                        }
                    } else if !refs.isEmpty {
                        scores = try await matcher.score(asked: label.asked, before: label.before ?? "",
                                                         candidates: refs.map(\.text))
                    }
                } catch {
                    print("  ! \(label.asked): \(error.localizedDescription)")
                }
                let seconds = Date().timeIntervalSince(start)
                let rank = label.expect.flatMap { e in refs.firstIndex { $0.text.localizedCaseInsensitiveContains(e) } }
                let row = Row(label: label, refs: refs, scores: scores, seconds: seconds, expectedRank: rank)
                rows.append(row)
                let bestText = row.best.map { refs[$0].text.replacingOccurrences(of: "\n", with: " ").prefix(60) } ?? ""
                let verdict: String
                switch row.hit(at: CallAnalysisEngine.docAnswerThreshold) {
                case .some(true): verdict = "HIT "
                case .some(false): verdict = label.expect == nil ? "FPOS" : "WRNG"
                case .none: verdict = label.expect == nil ? "ok  " : "miss"
                }
                print(String(format: "  %@ p=%.2f rank=%@ %.2fs | %@ → %@", verdict,
                             row.best.map { scores[$0] } ?? 0, rank.map(String.init) ?? "-", seconds,
                             label.asked, String(bestText)))
            }
            report(rows)
            exit(0)
        }
        dispatchMain()
    }

    static func report(_ rows: [Row]) {
        let covered = rows.filter { $0.label.expect != nil }
        print("\n=== retrieval (cosine top-8, question-only query) ===")
        print("expected chunk at rank 0: \(covered.filter { $0.expectedRank == 0 }.count)/\(covered.count), within top 4: \(covered.filter { ($0.expectedRank ?? 99) < 4 }.count), within top 8: \(covered.filter { $0.expectedRank != nil }.count)")
        print("\n=== precision / recall by threshold ===")
        for t in stride(from: 0.50, through: 0.90, by: 0.05) {
            var hits = 0, wrong = 0, falsePos = 0
            for r in rows {
                switch r.hit(at: t) {
                case .some(true): hits += 1
                case .some(false): if r.label.expect == nil { falsePos += 1 } else { wrong += 1 }
                case .none: break
                }
            }
            let shown = hits + wrong + falsePos
            let precision = shown == 0 ? 0 : Double(hits) / Double(shown)
            let recall = covered.isEmpty ? 0 : Double(hits) / Double(covered.count)
            print(String(format: "t=%.2f shown=%2d hits=%2d wrong=%2d falsePos=%2d precision=%.2f recall=%.2f",
                         t, shown, hits, wrong, falsePos, precision, recall))
        }
        for lang in Set(rows.compactMap { $0.label.lang }).sorted() {
            let sub = rows.filter { $0.label.lang == lang && $0.label.expect != nil }
            let hits = sub.filter { $0.hit(at: CallAnalysisEngine.docAnswerThreshold) == true }.count
            let none = rows.filter { $0.label.lang == lang && $0.label.expect == nil }
            let fpos = none.filter { $0.hit(at: CallAnalysisEngine.docAnswerThreshold) == false }.count
            print(String(format: "lang=%@: recall@%.2f = %d/%d, false positives %d/%d", lang,
                         CallAnalysisEngine.docAnswerThreshold, hits, sub.count, fpos, none.count))
        }
        let times = rows.map(\.seconds).sorted()
        if !times.isEmpty {
            print(String(format: "\nround trip p50=%.2fs p90=%.2fs max=%.2fs",
                         times[times.count / 2], times[Int(Double(times.count - 1) * 0.9)], times.last!))
        }
    }

    /// Reads the key through /usr/bin/security (the item's trusted app), so the
    /// unsigned dev binary never blocks on a Keychain consent dialog.
    static func keychainKey() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "com.uygar.parrot", "-a", JevDocMatcher.keychainAccount, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - --copilot-replay

/// Fixed-latency stand-in for Haiku so replay timing is deterministic. Emits
/// one "suggestion" per pass about the newest "Them" question in the window,
/// so the Haiku path produces a measurable first card.
final class StubAnalysisProvider: AnalysisProvider {
    let latency: TimeInterval
    private let lock = NSLock()
    private var totals = AITokenTotals()

    init(latency: TimeInterval) { self.latency = latency }

    var isConfigured: Bool { true }

    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult {
        try await Task.sleep(for: .seconds(latency))
        lock.lock()
        totals.calls += 1; totals.inputTokens += 900; totals.outputTokens += 250
        lock.unlock()
        let lines = request.transcript.split(separator: "\n").map(String.init)
        let lastQuestion = await MainActor.run {
            lines.last { $0.hasPrefix("Them:") && CallAnalysisEngine.looksLikeQuestion($0) }
        }
        let drafts = lastQuestion.map {
            [InsightDraft(kindKey: "suggestion", title: "Stub answer: \($0.dropFirst(6).prefix(60))",
                          detail: "stub", source: nil, reply: "stub reply")]
        } ?? []
        return AnalysisResult(insights: drafts, sentiment: ["score": 50], read: "stub", coach: nil, resolved: [])
    }

    func summarize(transcript: String, insightTitles: [String], instructions: String,
                   counterpart: String) async throws -> String { "" }

    func coachingReport(transcript: String, talkPercentMe: Int, instructions: String,
                        counterpart: String) async throws -> String { "" }

    var usageTotals: AITokenTotals { lock.lock(); defer { lock.unlock() }; return totals }

    func resetUsage() { lock.lock(); totals = AITokenTotals(); lock.unlock() }
}

/// Latency replay. Feeds a transcript export (`[mm:ss] Label: text`) into the
/// real engine at real time and logs, per "Them" question, the wall delay to
/// the first card and which path produced it.
///   .build/release/Parrot --copilot-replay export.txt [--pace fast] [--haiku-ms 2500] [--fast on|off] [--limit-seconds 600]
@MainActor
enum CopilotReplay {
    struct Line {
        let time: TimeInterval
        let source: AudioSource
        let text: String
    }

    /// `[mm:ss] Label: text` lines; "Me" is the user, any other label the
    /// other side (diarized exports say "Speaker 2"). Anything else is skipped.
    nonisolated static func parse(_ text: String) -> [Line] {
        text.split(separator: "\n").compactMap { raw in
            guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { return nil }
            let stamp = raw[raw.index(after: raw.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let m = Int(stamp[0]), let s = Int(stamp[1]) else { return nil }
            let rest = raw[raw.index(after: close)...].drop(while: { $0 == " " })
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            let label = rest[..<colon].trimmingCharacters(in: .whitespaces)
            let body = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { return nil }
            return Line(time: TimeInterval(m * 60 + s), source: label == "Me" ? .me : .them, text: body)
        }
    }

    static func run(transcriptPath: String, args: [String]) {
        func opt(_ name: String, _ fallback: String) -> String {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
            return args[i + 1]
        }
        let pace = opt("--pace", "fast")
        let haikuMs = Double(opt("--haiku-ms", "2500")) ?? 2500
        let fastOn = opt("--fast", "on") == "on"
        let limit = Double(opt("--limit-seconds", "600")) ?? 600
        UserDefaults.standard.register(defaults: [
            "copilotPace": pace, "copilotEnabled": true, "copilotProvider": "claude", "copilotWindow": "standard",
        ])
        Task { @MainActor in
            guard let text = try? String(contentsOfFile: transcriptPath, encoding: .utf8) else {
                print("copilot-replay: cannot read \(transcriptPath)"); exit(1)
            }
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
                let seconds = Date().timeIntervalSince(q.at)
                results.append((q.text, seconds, path))
                pendingQuestions.removeFirst()
                print(String(format: "  %5.2fs %-7@ ← %@", seconds, path, String(q.text.prefix(60))))
            }
            engine.start(profile: profile)
            let t0 = Date()
            for line in lines {
                let wait = t0.addingTimeInterval(line.time).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if line.source == .them, CallAnalysisEngine.looksLikeQuestion(line.text) {
                    pendingQuestions.append((line.text, Date()))
                }
                engine.ingest(text: line.text, at: line.time, source: line.source)
            }
            try? await Task.sleep(for: .seconds(max(8, haikuMs / 1000 + 6)))
            engine.stop()
            let minutes = max(1, (lines.last?.time ?? 60) / 60)
            report(results, calls: engine.provider.usageTotals.calls, minutes: minutes,
                   stats: engine.fastPathStats, unanswered: pendingQuestions.count)
            exit(0)
        }
        dispatchMain()
    }

    static func report(_ results: [(question: String, seconds: Double, path: String)], calls: Int,
                       minutes: Double, stats: (attempts: Int, hits: Int, failures: Int), unanswered: Int) {
        func pct(_ xs: [Double], _ p: Double) -> Double {
            let s = xs.sorted()
            return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))]
        }
        print("\n=== copilot-replay ===")
        for path in ["excerpt", "haiku"] {
            let xs = results.filter { $0.path == path }.map(\.seconds)
            print(String(format: "%-7@ n=%2d median=%.2fs p90=%.2fs max=%.2fs", path, xs.count, pct(xs, 0.5), pct(xs, 0.9), xs.max() ?? 0))
        }
        let all = results.map(\.seconds)
        print(String(format: "all     n=%2d median=%.2fs p90=%.2fs  unanswered=%d", all.count, pct(all, 0.5), pct(all, 0.9), unanswered))
        print(String(format: "haiku calls=%d (%.1f/min)  fast attempts=%d hits=%d failures=%d",
                     calls, Double(calls) / minutes, stats.attempts, stats.hits, stats.failures))
    }
}
