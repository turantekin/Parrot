import Foundation

/// What the release brings, in a few lines: the "What's new" card on Home
/// after updating and the notes in Sparkle's update window both read it.
/// /release-docs rewrites `current` for every release, and release.sh
/// refuses one whose version it doesn't name (`--whats-new-html`).
struct WhatsNew: Equatable {
    let version: String
    /// One light line, e.g. "Fresh feathers! Parrot 0.28.0".
    let headline: String
    /// Two to four one-liners in the user's terms; empty = a quiet release.
    let highlights: [String]

    /// The entry for the version being released. Empty highlights until the
    /// next release writes its own: no card, no notes.
    static let current = WhatsNew(version: "0.28.0", headline: "Parrot 0.28.0 learned a few new tricks", highlights: [
        "Each kind of call gets its own report. Shape it in Settings → Profiles → Report.",
        "Interviews get a scorecard: each point scored 1 to 5, with the moment that shows it.",
        "Rewrite an old report with any profile, and undo it in one click.",
        "Share profiles with a colleague, or let Claude suggest a better one for you to review.",
    ])

    /// For the help shot and the harness.
    static let sample = WhatsNew(
        version: "0.28.0", headline: "Fresh feathers! Parrot 0.28.0",
        highlights: [
            "Folders for your documents, with one Use for setting each.",
            "Calls stay smooth, even with years of meetings saved.",
            "Search finds Görüşme when you type gorusme.",
        ])

    /// The last version whose card was closed ("" before the first one).
    static let seenKey = "whatsNewSeenVersion"

    var hasNews: Bool { !highlights.isEmpty }

    /// The version's entry on the website changelog (each release has an anchor).
    var changelogURL: URL { URL(string: "https://openparrot.app/changelog#v\(version)")! }

    /// Home shows the card once, only for the version it describes, and
    /// never to someone still in the welcome tour.
    static func shouldShowCard(running: String, news: WhatsNew, seen: String, onboarded: Bool) -> Bool {
        onboarded && news.hasNews && news.version == running && seen != running
    }

    /// A fresh install starts with its version marked seen, so finishing
    /// onboarding never pops "What's new" at someone who is new to all of it.
    static func seenAfterLaunch(running: String, seen: String, onboarded: Bool) -> String {
        onboarded ? seen : running
    }

    /// Sparkle embeds this next to the update: no DOCTYPE or body, text escaped.
    func html() -> String {
        guard hasNews else { return "" }
        let items = highlights.map { "<li>\(Self.escape($0))</li>" }.joined()
        return "<h3>\(Self.escape(headline))</h3><ul>\(items)</ul>"
            + "<p><a href=\"\(changelogURL.absoluteString)\">Read the full story</a></p>"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The copy rules the release enforces.
    var copyProblems: [String] {
        var problems: [String] = []
        if ([headline] + highlights).contains(where: { $0.contains("—") }) { problems.append("no em-dashes") }
        if !(highlights.isEmpty || (2...4).contains(highlights.count)) { problems.append("0, or 2 to 4 highlights") }
        if highlights.contains(where: { $0.count > 90 }) { problems.append("each highlight 90 characters at most") }
        if hasNews && headline.isEmpty { problems.append("a headline") }
        return problems
    }

    /// `--whats-new-html X.Y.Z`, for release.sh: the fragment on stdout (nothing
    /// for a quiet release) and 0, or why not on stderr and 1.
    static func printHTML(for version: String, news: WhatsNew = .current) -> Int32 {
        guard news.version == version else {
            FileHandle.standardError.write(Data("WhatsNew.swift is written for \(news.version), not \(version).\n".utf8))
            return 1
        }
        guard news.copyProblems.isEmpty else {
            FileHandle.standardError.write(Data("WhatsNew.swift needs: \(news.copyProblems.joined(separator: ", ")).\n".utf8))
            return 1
        }
        let html = news.html()
        if !html.isEmpty { print(html) }
        return 0
    }
}
