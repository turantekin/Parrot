import Foundation

/// What a profile's end-of-call report looks like: its sections and its
/// coaching lens. Same shape as the `report` block of a `.parrotprofile`
/// (ProfileFile carries it as is). `.standard` is the report every profile
/// had before Profiles 2.0; its prompts are that report word for word
/// (golden-tested), so nobody who never touches templates sees a change.
struct ReportTemplate: Codable, Equatable {
    var sections: [Section]
    /// nil = the standard coaching (on, "sales/meeting coach", no focus).
    var coaching: Coaching?

    struct Section: Codable, Equatable {
        var key, title: String
        /// "prose" (a short paragraph), "bullets" or "scorecard".
        var type: String
        /// "What goes here", in the user's words.
        var guide: String?
        /// Bullets must be things someone said; they feed list_commitments,
        /// open items, Reminders and the receipts check.
        var commitments: Bool?
        var criteria: [Criterion]?
    }

    struct Criterion: Codable, Equatable {
        var key, label: String
        var guide: String?
    }

    struct Coaching: Codable, Equatable {
        var enabled: Bool
        var role: String?
        var focus: String?
    }

    static let maxSections = 8

    static let standard = ReportTemplate(sections: [
        Section(key: "overview", title: "Overview", type: "prose",
                guide: "2-3 sentences: what the call was about and how it ended."),
        Section(key: "pain", title: "Pain points", type: "bullets",
                guide: "What the other side is struggling with, what they're trying to achieve, and why."),
        Section(key: "key", title: "Key points", type: "bullets", guide: "Short bullets on what mattered."),
        Section(key: "next", title: "Next steps", type: "bullets",
                guide: "What someone said they'd do, with any date.", commitments: true),
    ], coaching: nil)

    static let standardCoachRole = "sales/meeting coach"

    var isStandard: Bool { self == .standard }
    var coachingEnabled: Bool { coaching?.enabled ?? true }

    var coachRole: String {
        let role = coaching?.role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return role.isEmpty ? Self.standardCoachRole : role
    }

    var coachFocus: String {
        coaching?.focus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Coaching that is on with no role or focus is the standard coaching,
    /// so an editor that touched and cleared a field doesn't make a copy.
    var normalized: ReportTemplate {
        var t = self
        if let c = t.coaching, c.enabled,
           (c.role ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (c.focus ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            t.coaching = nil
        }
        return t
    }

    /// Section titles, for the report parser to recognise as headings.
    var titles: [String] { sections.map(\.title).filter { !$0.isEmpty } }

    /// The template's own answer for a section title: its `commitments`
    /// flag, or nil when the title isn't one of its sections (coaching
    /// sections, reports written before the template).
    func commitmentFlag(forTitle title: String) -> Bool? {
        section(titled: title).map { $0.commitments == true }
    }

    /// The section a report heading belongs to (case, bold and colons ignored).
    func section(titled title: String) -> Section? {
        let t = Self.normalized(title)
        return sections.first { Self.normalized($0.title) == t }
    }

    static let maxCriteria = 8
    var hasScorecard: Bool { sections.contains { $0.type == "scorecard" } }

    /// In every prompt with a scorecard: criteria only, from what was said.
    static let fairnessRule = """
        Scorecards: score only the listed criteria, and only from what was said on the call. \
        Never judge age, gender, accent, looks or any other personal trait. Give no hire or \
        no-hire verdict unless a section asks for a recommendation.
        """

    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":*#"))).lowercased()
    }

    /// "a" or "an" before the coach role.
    // ponytail: first letter only, so "an user coach"; fine for roles people write.
    static func article(for word: String) -> String {
        guard let first = word.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }

    /// The summary prompt's structure paragraph for a custom template: one
    /// line per section, title first, so a small local model can follow it.
    var summaryStructure: String {
        // A section still being typed (no title yet) isn't asked for.
        let named = sections.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let lines = named.map { s -> String in
            var line = "\(s.title): "
            switch s.type {
            case "prose": line += "one short paragraph, no bullets."
            case "scorecard":
                // Written so small models copy the right shape. Seen on the
                // default local models: gemma3:4b pasted "(meaning)" into the
                // name (the reader copes) and dropped "/5"; llama3.2:3b copied
                // example words ("evidence", "why, in a few words") and any
                // "X is about: …" sentence as if they were answers.
                let criteria = s.criteria ?? []
                let first = criteria.first?.label ?? "Criterion"
                let listed = criteria.map { c -> String in
                    let guide = c.guide?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return guide.isEmpty ? c.label : "\(c.label) (\(guide))"
                }
                line += "a scorecard with one bullet for each of these criteria: " + listed.joined(separator: "; ")
                    + ". Write each like \"- \(first): 4/5 - reason [mm:ss]\": the name, a score from 1 to 5 "
                    + "written as N/5, a short reason, and the timestamp of the line that shows it. If the call doesn't show it, "
                    + "write \"- \(first): not enough evidence\". Never a score without its [mm:ss]."
            default: line += "\"-\" bullets, each ending with its [mm:ss]."
            }
            if let guide = s.guide?.trimmingCharacters(in: .whitespacesAndNewlines), !guide.isEmpty {
                line += " " + guide
            }
            if s.commitments == true {
                line += " Only what a person actually said they will do; if unsure, leave it out."
            }
            return line
        }
        return "Output exactly these sections, in this order, each title on its own line followed by a colon:\n"
            + lines.joined(separator: "\n")
            + "\nWrite only these sections, no others. If a section has nothing, write \"- None surfaced\" under its title. Use plain text with "
            + "simple \"-\" bullets, no markdown headers. Write in the same language as the conversation."
            + (hasScorecard ? "\n\n" + Self.fairnessRule : "")
    }
}

/// A scorecard section read back: one row per criterion, in the template's
/// order. A score counts only with a receipt that points at a real line and
/// only from 1 to 5; anything else leaves the criterion at "not enough
/// evidence". Lines that aren't scores come back as plain bullets.
enum Scorecard {
    struct Row: Equatable {
        let label: String
        /// nil = no score to show (see `uncited`).
        let score: Int?
        let evidence: String
        let lines: [ReceiptIndex.Line]
        /// The report gave a score but no moment that backs it, so it isn't
        /// shown; different from the call not showing enough.
        var uncited = false
    }

    // "Stage fit: 4/5 - They invest at seed [01:40]", bold or bulleted too.
    // A bare "4" counts when a dash, a receipt or nothing follows it.
    private static let scorePattern = try! NSRegularExpression(   // swiftlint:disable:this force_try
        pattern: #"^\s*(\d+)(?:\s*/\s*5\b|(?=\s*(?:[-–—\[(]|$)))\s*[-–—:,.]?\s*(.*)$"#)

    static func rows(from lines: [String], criteria: [ReportTemplate.Criterion],
                     receipts: ReceiptIndex) -> (rows: [Row], rest: [String]) {
        var found: [String: Row] = [:]
        var rest: [String] = []
        let bullets = CharacterSet(charactersIn: "-–•* ")
        for raw in lines {
            let line = raw.trimmingCharacters(in: bullets).replacingOccurrences(of: "**", with: "")
            // "Name (what it means): 4" counts as "Name: 4".
            guard let colon = line.firstIndex(of: ":") else { rest.append(raw); continue }
            let name = String(line[..<colon]).replacingOccurrences(of: #"\s*\(.*\)\s*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard let criterion = criteria.first(where: {
                $0.label.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame })
            else { rest.append(raw); continue }
            let key = criterion.label.lowercased()
            let body = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if body.lowercased().hasPrefix("not enough evidence") {
                if found[key] == nil { found[key] = Row(label: criterion.label, score: nil, evidence: "", lines: []) }
                continue
            }
            let ns = body as NSString
            guard let m = scorePattern.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else {
                rest.append(raw); continue
            }
            let score = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let cited = Receipts.extract(ns.substring(with: m.range(at: 2)))
            let backed = receipts.lines.isEmpty ? [] : receipts.verified(cited.times)
            let hasReceipt = receipts.lines.isEmpty ? !cited.times.isEmpty : !backed.isEmpty
            // Out of range or unbacked: dropped, the criterion stays unscored.
            guard (1...5).contains(score) else { continue }
            guard hasReceipt else {
                if found[key] == nil { found[key] = Row(label: criterion.label, score: nil, evidence: "", lines: [], uncited: true) }
                continue
            }
            if found[key]?.score == nil {
                // Tidy a leading dash, and "reason:" copied from the prompt's example.
                let evidence = cited.text.trimmingCharacters(in: CharacterSet(charactersIn: "-–—:, "))
                    .replacingOccurrences(of: #"^reason\s*[:\-–—]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
                found[key] = Row(label: criterion.label, score: score, evidence: evidence, lines: backed)
            }
        }
        let rows = criteria.map { c in
            found[c.label.lowercased()] ?? Row(label: c.label, score: nil, evidence: "", lines: [])
        }
        return (rows, rest)
    }
}
