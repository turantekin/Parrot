import Foundation

/// "What did I promise?": the bullets under a report's commitment sections
/// (next steps, commitments, follow-ups…), each with an owner. The owner is
/// what the report's own wording says ("You to send…", "Vendor will…",
/// "Sam shares…"): the report calls the user "you" by rule. Who spoke the
/// line the `[mm:ss]` receipt points at is kept too, as evidence, but it is
/// not the owner: a receipt often cites the request, not the promise.
/// Nothing in the wording, no owner ("unclear"), never a guess.
enum MCPCommitments {

    struct Item: Equatable {
        var meetingID: UUID
        var title: String
        var date: Date
        var text: String
        /// "Me", a person's name, or a role ("Vendor"); nil when the wording doesn't say.
        var owner: String?
        /// Who spoke the cited line, and when.
        var saidBy: String?
        var stamp: String?
    }

    /// Commitment bullets from the meeting's report texts (summary, coaching),
    /// in order. Placeholders ("- None") are skipped, and a promise the
    /// coaching restates from the next steps counts once.
    static func items(meetingID: UUID, title: String, date: Date, people: [String] = [],
                      reports: [String?], template: ReportTemplate?, index: ReceiptIndex) -> [Item] {
        var out: [Item] = []
        for text in reports.compactMap({ $0 }) {
            // Section titles go through Receipts, so report templates that
            // flag their own commitment sections join in one place.
            for section in ReportProse.sections(from: text, template: template)
            where Receipts.isCommitmentSection(section.title, in: template) {
                for block in section.blocks {
                    guard case .bullet(let raw, _) = block else { continue }
                    let cited = Receipts.extract(raw)
                    guard !Receipts.isPlaceholder(cited.text),
                          !out.contains(where: { CallAnalysisEngine.isNearDuplicate($0.text, cited.text, threshold: 0.8) })
                    else { continue }
                    let line = index.verified(cited.times).first
                    out.append(Item(meetingID: meetingID, title: title, date: date, text: cited.text,
                                    owner: owner(of: cited.text, people: people), saidBy: line?.speaker,
                                    stamp: line.map { Receipts.stamp($0.start) }))
                }
            }
        }
        return out
    }

    private static let subjectPattern = try! NSRegularExpression(   // swiftlint:disable:this force_try
        pattern: #"^(?:the\s+)?([\p{L}][\p{L}-]*)\s+(?:to|will|shall|'ll|’ll|agreed|agrees|promised|promises|committed|commits|offered|offers|must|should|needs to|need to|is to|are to)\b"#,
        options: [.caseInsensitive])

    /// Who the bullet says will do it. "You…"/"I…" is the user; a name from
    /// the meeting is that person; "Vendor to…", "The prospect will…" is that
    /// role; "They…" the other side. "We…", "Both…" and imperatives
    /// ("Send the invite") name no one.
    /// ponytail: English wording only; Turkish reports come back "unclear".
    static func owner(of text: String, people: [String]) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "’", with: "'")
        let first = t.prefix { $0.isLetter || $0 == "'" }.lowercased()
        if ["you", "you'll", "your", "i", "i'll"].contains(first) { return "Me" }
        if ["they", "they'll", "their"].contains(first) { return "Them" }
        let lower = t.lowercased()
        for person in people where !person.isEmpty {
            let given = person.split(separator: " ").first.map(String.init) ?? person
            for name in [person, given] where lower.hasPrefix(name.lowercased() + " ") || lower.hasPrefix(name.lowercased() + "'") {
                return person
            }
        }
        let ns = t as NSString
        guard let m = subjectPattern.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let subject = ns.substring(with: m.range(at: 1))
        guard !["we", "both", "everyone", "all", "someone", "follow-up", "call", "meeting", "next"].contains(subject.lowercased())
        else { return nil }
        return subject.prefix(1).uppercased() + subject.dropFirst()
    }

    /// `owner`: "me", "others" (someone named, not me) or part of a name.
    static func matches(_ item: Item, owner: String) -> Bool {
        let wanted = owner.lowercased().trimmingCharacters(in: .whitespaces)
        let who = item.owner?.lowercased()
        switch wanted {
        case "", "anyone": return true
        case "me": return who == "me"
        case "others": return who != nil && who != "me"
        default: return who?.contains(wanted) == true
        }
    }
}
