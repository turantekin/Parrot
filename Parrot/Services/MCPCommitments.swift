import Foundation

/// "What did I promise?": the bullets under a report's commitment sections
/// (next steps, commitments, follow-ups…), each with an owner. The owner is
/// whoever said the transcript line the bullet's `[mm:ss]` receipt points
/// at: a lookup, never a guess. No valid receipt, no owner ("unclear").
enum MCPCommitments {

    struct Item: Equatable {
        var meetingID: UUID
        var title: String
        var date: Date
        var text: String
        var owner: String?
        var stamp: String?
    }

    /// Commitment bullets from the meeting's report texts (summary, coaching),
    /// in order. Placeholders ("- None") are skipped, and a promise the
    /// coaching restates from the next steps counts once.
    static func items(meetingID: UUID, title: String, date: Date,
                      reports: [String?], index: ReceiptIndex) -> [Item] {
        var out: [Item] = []
        for text in reports.compactMap({ $0 }) {
            // Section titles go through Receipts, so report templates that
            // flag their own commitment sections join in one place.
            for section in ReportProse.sections(from: text) where Receipts.isCommitmentSection(section.title) {
                for block in section.blocks {
                    guard case .bullet(let raw, _) = block else { continue }
                    let cited = Receipts.extract(raw)
                    guard !Receipts.isPlaceholder(cited.text),
                          !out.contains(where: { CallAnalysisEngine.isNearDuplicate($0.text, cited.text, threshold: 0.8) })
                    else { continue }
                    let line = index.verified(cited.times).first
                    out.append(Item(meetingID: meetingID, title: title, date: date, text: cited.text,
                                    owner: line?.speaker, stamp: line.map { Receipts.stamp($0.start) }))
                }
            }
        }
        return out
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
