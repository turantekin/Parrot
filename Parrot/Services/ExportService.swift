import Foundation

/// Exports meeting transcripts to TXT and SRT formats.
enum ExportService {

    enum Format: String {
        case markdown, txt, srt
        var fileExtension: String { self == .markdown ? "md" : rawValue }
    }

    /// Which parts of a meeting an export holds. The app exports everything;
    /// an AI app only gets what the user shares with it.
    struct Parts: OptionSet {
        let rawValue: Int
        static let transcript = Parts(rawValue: 1)
        static let report = Parts(rawValue: 2)
        static let notes = Parts(rawValue: 4)
        static let cards = Parts(rawValue: 8)
        static let all: Parts = [.transcript, .report, .notes, .cards]
    }

    @MainActor
    static func content(for meeting: Meeting, format: Format, parts: Parts = .all) -> String {
        switch format {
        case .markdown: return exportToMarkdown(meeting: meeting, parts: parts)
        case .txt: return exportToTXT(meeting: meeting, parts: parts)
        case .srt: return exportToSRT(meeting: meeting, parts: parts)
        }
    }

    // MARK: - Plain Text Export

    static func exportToTXT(meeting: Meeting, parts: Parts = .all) -> String {
        var output = """
        Meeting: \(meeting.title)
        Date: \(formatDate(meeting.date))
        Duration: \(meeting.formattedDuration)
        Speakers: \(meeting.speakerCount)

        """

        if parts.contains(.notes), !meeting.notes.isEmpty {
            output += """

            === My Notes ===

            \(meeting.notes)

            """
        }

        if let consent = meeting.consent {
            output += "\nRecording consent: \(consent.summary)\n"
        }

        let marks = meeting.bookmarks
        if !marks.isEmpty {
            output += "\n=== Moments You Marked ===\n\n"
            for mark in marks {
                output += "[\(Receipts.stamp(mark.time))] \(mark.label.isEmpty ? "Marked moment" : mark.label)\n"
            }
        }

        if parts.contains(.report), let summary = meeting.summary {
            output += """

            === Summary ===

            \(summary)

            """
        }

        if parts.contains(.report), let coaching = meeting.coaching {
            output += """

            === Coaching & Follow-ups ===

            \(coaching)

            """
        }

        if parts.contains(.cards), !meeting.insights.isEmpty {
            output += "\n=== Copilot Insights ===\n\n"
            for insight in meeting.sortedInsights {
                let style = KindResolver.style(forKey: insight.kindRaw, profile: meeting.profile, snapshot: meeting.snapshotKinds)
                var line = "[\(insight.formattedCallTime)] \(style.label): \(insight.title)"
                if style.isPinned {
                    line += insight.isHandled ? " (handled)" : " (UNRESOLVED)"
                }
                output += line + "\n"
                output += "    \(insight.detail)\n"
                if let source = insight.source {
                    output += "    Source: \(source)\n"
                }
            }
        }

        guard parts.contains(.transcript) else { return output }
        output += "\n=== Transcript ===\n\n"
        for segment in meeting.sortedSegments {
            let speaker = meeting.displayName(forSpeaker: segment.speakerLabel)
            output += "[\(segment.formattedTimestamp)] \(speaker): \(segment.text)\n"
        }

        return output
    }

    // MARK: - Markdown Export

    /// Obsidian/Notion-friendly Markdown: YAML front matter, then notes,
    /// report (receipts kept as `12:34`), marked moments, next steps as
    /// tasks, and the transcript. `parrot_id` lets a re-export overwrite the
    /// same note.
    @MainActor
    static func exportToMarkdown(meeting: Meeting, parts: Parts = .all) -> String {
        var out = "---\n"
        out += "title: \(yamlString(meeting.title))\n"
        out += "date: \(ISO8601DateFormatter().string(from: meeting.date))\n"
        out += "duration_minutes: \(Int((meeting.duration / 60).rounded()))\n"
        let people = meeting.attendees.map(\.displayName).filter { !$0.isEmpty }
            + meeting.speakerNames.values.filter { !$0.isEmpty }
        var seen = Set<String>()
        let uniquePeople = people.filter { seen.insert($0.lowercased()).inserted }
        if !uniquePeople.isEmpty {
            out += "people: [\(uniquePeople.map(yamlString).joined(separator: ", "))]\n"
        }
        if let profile = meeting.profile?.name { out += "profile: \(yamlString(profile))\n" }
        out += "source: parrot\n"
        out += "parrot_id: \(meeting.id.uuidString)\n"
        out += "---\n\n"
        out += "# \(meeting.title)\n\n"

        if let consent = meeting.consent {
            out += "> Recording consent: \(consent.summary)\n\n"
        }
        if parts.contains(.notes), !meeting.notes.isEmpty {
            out += "## My notes\n\n\(meeting.notes)\n\n"
        }
        // The checklist replaces the report's own next-step and commitment
        // sections, which listed the same promises a second time.
        let summary = parts.contains(.report) ? meeting.summary : nil
        let coaching = parts.contains(.report) ? meeting.coaching : nil
        let steps = LastCallBrief.openItems(summary: summary, coaching: coaching, limit: 20)
        if let summary {
            out += "## Summary\n\n\(markdownReport(summary, skipCommitments: !steps.isEmpty))\n\n"
        }
        if !steps.isEmpty {
            out += "## Next steps\n\n" + steps.map { "- [ ] \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if let coaching {
            out += "## Coaching\n\n\(markdownReport(coaching, skipCommitments: !steps.isEmpty))\n\n"
        }
        let marks = meeting.bookmarks
        if !marks.isEmpty {
            out += "## Moments I marked\n\n"
            out += marks.map { "- `\(Receipts.stamp($0.time))` \($0.label.isEmpty ? "Marked moment" : $0.label)" }
                .joined(separator: "\n") + "\n\n"
        }
        if parts.contains(.report), let email = meeting.followUpEmail, !email.isEmpty {
            out += "## Follow-up email (draft)\n\n\(email)\n\n"
        }
        guard parts.contains(.transcript) else { return out }
        out += "## Transcript\n\n"
        for segment in meeting.sortedSegments {
            let speaker = meeting.displayName(forSpeaker: segment.speakerLabel)
            out += "`\(segment.formattedTimestamp)` **\(speaker):** \(segment.text)  \n"
        }
        return out
    }

    /// Report text with `[12:34]` receipts as inline code, headings as ###.
    static func markdownReport(_ text: String, skipCommitments: Bool = false) -> String {
        var skipping = false
        return ReportProse.unflattened(text).components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":"), trimmed.split(separator: " ").count <= 7, !trimmed.hasPrefix("-") {
                skipping = skipCommitments && Receipts.isCommitmentSection(String(trimmed.dropLast()))
                return skipping ? nil : "### " + String(trimmed.dropLast())
            }
            if skipping { return nil }
            let cited = Receipts.extract(line)
            guard !cited.times.isEmpty else { return line }
            let lead = String(line.prefix { $0 == " " || $0 == "\t" })
            return lead + cited.text + " " + cited.times.map { "`\(Receipts.stamp($0))`" }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// "2026-09-25 14-30 Acme renewal.md": sorts by date, safe on every FS.
    static func markdownFilename(for meeting: Meeting) -> String {
        filename(title: meeting.title, date: meeting.date, format: .markdown)
    }

    static func filename(title: String, date: Date, format: Format) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let title = title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(title.prefix(80))
        return "\(f.string(from: date)) \(short.isEmpty ? "Meeting" : short).\(format.fileExtension)"
    }

    private static func yamlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") + "\""
    }

    // MARK: - SRT Export

    static func exportToSRT(meeting: Meeting, parts: Parts = .all) -> String {
        var output = ""
        guard parts.contains(.transcript) else { return output }
        let segments = meeting.sortedSegments

        for (index, segment) in segments.enumerated() {
            let speaker = segment.speakerLabel != nil ? "[\(meeting.displayName(forSpeaker: segment.speakerLabel))] " : ""
            output += """
            \(index + 1)
            \(srtTimestamp(segment.startTime)) --> \(srtTimestamp(segment.endTime))
            \(speaker)\(segment.text)


            """
        }

        return output
    }

    // MARK: - Save to File

    static func save(content: String, filename: String, extension ext: String) throws -> URL {
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        // Filenames come from user-typed meeting titles — "/" and ":" break the
        // path, and identical titles must not silently overwrite prior exports.
        let safe = filename
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
        var url = downloadsDir.appendingPathComponent("\(safe).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = downloadsDir.appendingPathComponent("\(safe) (\(n)).\(ext)")
            n += 1
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Helpers

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
