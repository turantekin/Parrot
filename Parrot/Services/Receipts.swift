import Foundation

/// "Receipts": the report prompts ask the model to end every bullet with the
/// `[mm:ss]` of the transcript line that supports it. This file turns those
/// stamps into checked references — pure logic, no UI, harness-covered.
///
/// The prompt is the first line of defence; `ReceiptIndex.resolve` is the
/// backstop. A stamp only becomes a clickable chip when a real transcript line
/// sits at that moment, so a model that invents "[41:07]" in a 30-minute call
/// gets no chip, and a commitment with no surviving receipt is shown as
/// unverified instead of stated as fact.
enum Receipts {

    /// One line of report text with its stamps lifted out.
    struct Cited: Equatable {
        /// The text with every timestamp group removed and spacing tidied.
        let text: String
        /// Every stamp found, in order, as call-time seconds (unvalidated).
        let times: [TimeInterval]
    }

    /// A stamp's seconds: `m:ss`, `mm:ss`, `mmm:ss` (minutes run past 59 —
    /// that's how `TranscriptSegment.formattedTimestamp` writes a long call) or
    /// `h:mm:ss`. Seconds (and minutes, in the three-part form) must be < 60.
    static func parseStamp(_ raw: String) -> TimeInterval? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let last = parts.last, last.count == 2 else { return nil }
        let nums = parts.compactMap { Int($0) }
        guard nums.count == parts.count else { return nil }
        switch nums.count {
        case 2:
            guard nums[1] < 60 else { return nil }
            return TimeInterval(nums[0] * 60 + nums[1])
        case 3:
            guard nums[1] < 60, nums[2] < 60, parts[1].count == 2 else { return nil }
            return TimeInterval(nums[0] * 3600 + nums[1] * 60 + nums[2])
        default:
            return nil
        }
    }

    /// Same shape the transcript is sent to the model in (`mm:ss`, minutes
    /// unbounded), so a chip reads exactly like the line it points at.
    static func stamp(_ time: TimeInterval) -> String {
        let t = max(0, Int(time))
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    // Matches one bracketed group holding ONLY stamps and separators:
    // "[12:34]", "[12:34, 15:02]", "[12:34–13:10]", "(1:02:03)". Text like
    // "[sic]" or "(see 2:30 pm)" is left alone — only a group that is nothing
    // but stamps is treated as a citation.
    private static let groupPattern: NSRegularExpression = {
        let stamp = #"\d{1,3}:\d{2}(?::\d{2})?"#
        let sep = #"\s*(?:,|;|–|—|-|and|&)\s*"#
        let body = "\(stamp)(?:\(sep)\(stamp))*"
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: #"\s*(?:\[\s*"# + body + #"\s*\]|\(\s*"# + body + #"\s*\))"#)
    }()

    private static let stampPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\d{1,3}:\d{2}(?::\d{2})?"#)
    }()

    /// Lifts every citation group out of `line`. Order of stamps is kept;
    /// duplicates are dropped.
    static func extract(_ line: String) -> Cited {
        let ns = line as NSString
        let groups = groupPattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !groups.isEmpty else { return Cited(text: line, times: []) }

        var times: [TimeInterval] = []
        var kept = ""
        var cursor = 0
        for group in groups {
            kept += ns.substring(with: NSRange(location: cursor, length: group.range.location - cursor))
            cursor = group.range.location + group.range.length
            let groupText = ns.substring(with: group.range)
            let g = groupText as NSString
            for m in stampPattern.matches(in: groupText, range: NSRange(location: 0, length: g.length)) {
                if let t = parseStamp(g.substring(with: m.range)), !times.contains(t) {
                    times.append(t)
                }
            }
        }
        kept += ns.substring(from: cursor)
        return Cited(text: tidy(kept), times: times)
    }

    /// Collapses the double spaces and " ." left where a group was cut out.
    private static func tidy(_ s: String) -> String {
        var out = s
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        for p in [".", ",", ";", ":", "!", "?"] {
            out = out.replacingOccurrences(of: " \(p)", with: p)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// True for section titles whose bullets are claims about promises —
    /// the ones where an invented line does real harm ("you promised the
    /// contract by Friday"). A bullet there with no valid receipt is flagged.
    static func isCommitmentSection(_ title: String?) -> Bool {
        guard let t = title?.lowercased() else { return false }
        return ["next step", "commit", "follow", "action item", "promise"].contains { t.contains($0) }
    }

    /// "- None", "- None surfaced", "- N/A": placeholders that need no receipt.
    static func isPlaceholder(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return t.isEmpty || t == "none" || t.hasPrefix("none ") || t == "n/a" || t == "nothing"
    }
}

/// The transcript's time spans, for checking stamps. Built once per render
/// from the meeting's segments (or seeded directly in the harness).
struct ReceiptIndex: Equatable {

    struct Line: Equatable {
        let start: TimeInterval
        let end: TimeInterval
        let speaker: String
        let text: String
    }

    /// Sorted by start time.
    let lines: [Line]

    init(lines: [Line]) {
        self.lines = lines.sorted { $0.start < $1.start }
    }

    /// Slack either side of a line. The model sees `mm:ss` of the START
    /// (floored), so a stamp can sit up to a second before the true start;
    /// it may also quote the moment mid-line. Beyond a few seconds of any
    /// spoken line the stamp points at silence — not a receipt.
    static let tolerance: TimeInterval = 3

    /// The line a stamp points at, or nil when nothing was said there.
    /// Prefers the line whose start is nearest the stamp (the model copies
    /// start stamps); falls back to a line the stamp lands inside.
    func resolve(_ time: TimeInterval) -> Line? {
        guard time.isFinite, time >= 0 else { return nil }
        let candidates = lines.filter {
            time >= $0.start - Self.tolerance && time <= $0.end + Self.tolerance
        }
        return candidates.min { abs($0.start - time) < abs($1.start - time) }
    }

    /// Stamps that point at real lines, deduplicated by the line they hit, in
    /// the order the model wrote them.
    func verified(_ times: [TimeInterval]) -> [Line] {
        var seen: [Line] = []
        for t in times {
            if let line = resolve(t), !seen.contains(line) { seen.append(line) }
        }
        return seen
    }

    static let empty = ReceiptIndex(lines: [])

    /// Whether this report was written under the receipts rule at all: any
    /// stamp anywhere that resolves. Reports from before Receipts (or from a
    /// model that ignored the rule entirely) render exactly as before — no
    /// "unverified" flags on text that never claimed a source.
    func reportHasReceipts(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { !verified(Receipts.extract($0).times).isEmpty }
    }
}
