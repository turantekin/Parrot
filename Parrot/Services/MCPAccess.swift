import Foundation

/// What the user lets a connected AI app see, and the activity line's
/// counters. Read fresh on every request, so a change in Parrot applies to a
/// running AI app at once. The defaults are exactly what the first version
/// shared (transcripts, reports, notes, marked moments; no cards), so people
/// who connected before these settings existed see no change.
struct MCPAccess: Equatable {

    static let transcriptsKey = "mcpShareTranscripts"
    static let reportsKey = "mcpShareReports"
    static let notesKey = "mcpShareNotes"
    static let cardsKey = "mcpShareCards"
    static let excludedKey = "mcpExcludedProfileIDs"

    var transcripts = true
    var reports = true
    var notes = true
    var cards = false
    /// Call profiles whose meetings stay hidden.
    var excludedProfiles: Set<UUID> = []

    init(transcripts: Bool = true, reports: Bool = true, notes: Bool = true, cards: Bool = false,
         excludedProfiles: Set<UUID> = []) {
        self.transcripts = transcripts
        self.reports = reports
        self.notes = notes
        self.cards = cards
        self.excludedProfiles = excludedProfiles
    }

    init(defaults: UserDefaults) {
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        self.init(transcripts: flag(Self.transcriptsKey, true), reports: flag(Self.reportsKey, true),
                  notes: flag(Self.notesKey, true), cards: flag(Self.cardsKey, false),
                  excludedProfiles: Set((defaults.stringArray(forKey: Self.excludedKey) ?? []).compactMap(UUID.init)))
    }

    var parts: ExportService.Parts {
        var parts: ExportService.Parts = []
        if transcripts { parts.insert(.transcript) }
        if reports { parts.insert(.report) }
        if notes { parts.insert(.notes) }
        if cards { parts.insert(.cards) }
        return parts
    }

    var searchableKinds: Set<MemoryChunk.Kind> {
        var kinds: Set<MemoryChunk.Kind> = []
        if transcripts { kinds.insert(.transcript) }
        if reports { kinds.insert(.report) }
        return kinds
    }

    /// nil hides the meeting; otherwise the parts the user unticked are gone.
    func filter(_ info: MCPServer.MeetingInfo) -> MCPServer.MeetingInfo? {
        if let profile = info.profileID, excludedProfiles.contains(profile) { return nil }
        var out = info
        if !reports { out.summary = nil; out.coaching = nil }
        if !notes { out.notes = "" }
        return out
    }

    /// The source every tool reads through: one place, so no tool (search
    /// and exports included) can reach a part the user unticked.
    func gate(_ source: MCPServer.DataSource) -> MCPServer.DataSource {
        var out = source
        out.meetings = { source.meetings().compactMap(filter) }
        if !transcripts { out.transcript = { _ in [] } }
        if !cards { out.cards = { _ in [] } }
        let shared = searchableKinds
        out.search = { query, ids, wanted, limit in
            let kinds = wanted.intersection(shared)
            guard !kinds.isEmpty else { return [] }
            return await source.search(query, ids, kinds, limit).filter { kinds.contains($0.kind) }
        }
        let allowed = parts
        out.export = { id, format, wanted in source.export(id, format, wanted.intersection(allowed)) }
        return out
    }

    // MARK: Activity (written by the --mcp process; counts and times only)

    static let lastReadKey = "mcpLastReadAt"
    static let readsTodayKey = "mcpReadsToday"
    static let firstReadKey = "mcpFirstReadAt"

    /// One AI-app read of meeting content.
    static func recordRead(in defaults: UserDefaults = .standard, now: Date = .now, calendar: Calendar = .current) {
        let last = defaults.object(forKey: lastReadKey) as? Date
        let today = last.map { calendar.isDate($0, inSameDayAs: now) } == true ? defaults.integer(forKey: readsTodayKey) : 0
        defaults.set(today + 1, forKey: readsTodayKey)
        defaults.set(now, forKey: lastReadKey)
        if defaults.object(forKey: firstReadKey) == nil { defaults.set(now, forKey: firstReadKey) }
    }

    /// Today's reads, 0 when the last read was on another day.
    static func readsToday(in defaults: UserDefaults = .standard, now: Date = .now, calendar: Calendar = .current) -> Int {
        guard let last = defaults.object(forKey: lastReadKey) as? Date, calendar.isDate(last, inSameDayAs: now) else { return 0 }
        return defaults.integer(forKey: readsTodayKey)
    }
}
