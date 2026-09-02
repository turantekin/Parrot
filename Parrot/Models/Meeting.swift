import Foundation
import SwiftData

enum MeetingStatus: String, Codable {
    case recording
    case processing
    case done
    case failed
}

@Model
final class Meeting {
    var id: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var systemAudioPath: String
    var micAudioPath: String?
    var status: MeetingStatus
    var errorMessage: String?
    /// AI-generated post-call report; set shortly after recording stops.
    var summary: String?
    /// AI coaching + follow-ups report (talk ratio, what to improve, commitments).
    var coaching: String?
    /// User-assigned name for the other party ("Them"), e.g. "Sam". When set, it
    /// replaces "Them"/"Speaker N" labels in the transcript and reports.
    var themName: String?
    /// The user's own typed notes for this call — live during recording (side
    /// panel) and editable afterwards (Notes tab). Defaulted → old rows migrate.
    var notes: String = ""

    /// True when this meeting was salvaged from an interrupted recording (crash or
    /// force-quit) on the next launch, rather than finished cleanly. Drives the
    /// "Recovered" badge/banner. Defaulted → old rows migrate.
    var wasRecovered: Bool = false

    /// Profile recorded under (nil for pre-Phase-C meetings).
    var profile: CallProfile?
    /// One-line brief for this specific call (was ephemeral nextCallBrief).
    var brief: String?
    /// Denormalized [ProfileKind] used at record time, so the report renders with
    /// the right kind labels/colors even if the profile is later edited/deleted.
    var profileSnapshotData: Data?
    /// Per-call AI usage/cost snapshot (AIUsage JSON); nil for meetings recorded
    /// before cost tracking existed — those show no cost row.
    var aiUsageData: Data?
    /// Mean voice embedding per speaker label (JSON [String: [Float]]), written
    /// by diarization; feeds voice profiles later. Defaulted → old rows migrate.
    var speakerEmbeddingsData: Data? = nil
    /// Per-speaker display names (JSON [label: name]); set from the naming UI.
    /// Defaulted → old rows migrate.
    var speakerNamesData: Data? = nil
    /// One-time "name the voices" card dismissed. Defaulted → old rows migrate.
    var speakerPromptDismissed: Bool = false

    /// When the user last trimmed the tail off this transcript, nil if never.
    /// Drives the footer note — a transcript that stops mid-call should say why
    /// it stops there. Defaulted → old rows migrate.
    var truncatedAt: Date? = nil
    /// Call time of the last line kept by that trim.
    var truncatedAfterTime: TimeInterval = 0
    /// Lines removed, summed over every trim on this meeting.
    var truncatedLineCount: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    var segments: [TranscriptSegment]

    @Relationship(deleteRule: .cascade, inverse: \CallInsight.meeting)
    var insights: [CallInsight]

    init(
        title: String? = nil,
        date: Date = .now,
        systemAudioPath: String = "",
        micAudioPath: String? = nil
    ) {
        self.id = UUID()
        self.title = title ?? Self.defaultTitle(for: date)
        self.date = date
        self.duration = 0
        self.systemAudioPath = systemAudioPath
        self.micAudioPath = micAudioPath
        self.status = .recording
        self.errorMessage = nil
        self.summary = nil
        self.segments = []
        self.insights = []
    }

    var sortedInsights: [CallInsight] {
        insights.sorted { $0.callTime < $1.callTime }
    }

    static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return "Meeting \(formatter.string(from: date))"
    }

    var sortedSegments: [TranscriptSegment] {
        segments.sorted { $0.startTime < $1.startTime }
    }

    /// The tail of the transcript below `segment` — what a truncate removes.
    /// Judged by start time, the order the user is reading, not by insertion
    /// order. A line sharing the anchor's exact start time stays: nothing above
    /// the clicked line should ever disappear.
    func segments(after segment: TranscriptSegment) -> [TranscriptSegment] {
        segments.filter { $0.startTime > segment.startTime }
    }

    /// Drops everything after `segment`, for the run of invented text Whisper
    /// produces when a recording is left running on an empty room. The audio
    /// file is deliberately left alone — storage is cheap, and it means a
    /// mis-clicked line costs the transcript, not the recording. Returns how
    /// many lines went.
    @discardableResult
    func truncate(after segment: TranscriptSegment, in context: ModelContext) -> Int {
        // A meeting still being transcribed is having segments appended to it as
        // we work — a cut would be undone by the next batch to land, leaving a
        // receipt that lies about what the transcript holds. Enforced here, not
        // just in the menu, so no caller can get it wrong.
        guard status == .done else { return 0 }
        // Snapshot first: deleting mutates the relationship we're filtering.
        let tail = segments(after: segment)
        guard !tail.isEmpty else { return 0 }
        for stale in tail { context.delete(stale) }
        // Stamped so the transcript can say why it stops where it stops. Trims
        // accumulate: the count is every line this meeting has lost, the time is
        // the most recent cut — which is always the earliest one.
        truncatedAt = .now
        truncatedAfterTime = segment.startTime
        truncatedLineCount += tail.count
        try? context.save()
        return tail.count
    }

    static func noteLines(_ count: Int) -> String {
        count == 1 ? "1 line" : "\(count) lines"
    }

    /// Footer line for a trimmed transcript; nil when nothing was ever cut.
    /// The call time is formatted like the transcript rows (mm:ss, minutes
    /// running past 60) so it names a timestamp the user can actually see.
    var truncationNote: String? {
        guard let truncatedAt, truncatedLineCount > 0 else { return nil }
        let stamp = String(format: "%02d:%02d",
                           Int(truncatedAfterTime) / 60, Int(truncatedAfterTime) % 60)
        let lines = Self.noteLines(truncatedLineCount)
        let when = truncatedAt.formatted(date: .abbreviated, time: .shortened)
        return "You deleted \(lines) after \(stamp) on \(when). The recording still has the full audio."
    }

    var snapshotKinds: [ProfileKind] {
        guard let data = profileSnapshotData else { return [] }
        return (try? JSONDecoder().decode([ProfileKind].self, from: data)) ?? []
    }

    var aiUsage: AIUsage? {
        guard let data = aiUsageData else { return nil }
        return try? JSONDecoder().decode(AIUsage.self, from: data)
    }

    /// Number of distinct participants by display name. Counting display names
    /// (not raw labels) means that once the other party is named, the imperfect
    /// diarization splitting one voice into "Speaker 1"/"Speaker 2" collapses back
    /// to a single person — so a 1-on-1 reads as 2, not 3.
    var speakerCount: Int {
        Set(segments.map { displayName(forSpeaker: $0.speakerLabel) }).count
    }

    /// Human-facing speaker name. Precedence: a per-speaker name from the
    /// naming UI wins; "Me" stays "Me"; before any per-speaker naming the
    /// legacy collective `themName` still covers the whole other side; once
    /// naming has started, unnamed voices show their raw "Speaker N" label
    /// (mixing "Gürkan" with a collective name would misattribute lines).
    func displayName(forSpeaker label: String?) -> String {
        let names = speakerNames
        guard let label, !label.isEmpty else {
            return names.isEmpty ? (themName ?? "Them") : "Them"
        }
        if let assigned = names[label] { return assigned }
        if label == "Me" { return "Me" }
        return names.isEmpty ? (themName ?? label) : label
    }

    /// Mean voice embedding per label, as written by diarization.
    var speakerEmbeddings: [String: [Float]] {
        guard let data = speakerEmbeddingsData else { return [:] }
        return (try? JSONDecoder().decode([String: [Float]].self, from: data)) ?? [:]
    }

    /// Per-speaker display names (see `speakerNamesData`).
    var speakerNames: [String: String] {
        get {
            guard let data = speakerNamesData else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set { speakerNamesData = try? JSONEncoder().encode(newValue) }
    }

    /// Distinct non-Me speaker labels, "Speaker 1" first.
    var otherSpeakerLabels: [String] {
        Set(segments.compactMap(\.speakerLabel)).subtracting(["Me"])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// This voice's longest utterances — the clips the naming UI plays.
    func longestSegments(for label: String, count: Int = 3) -> [TranscriptSegment] {
        segments.filter { $0.speakerLabel == label }
            .sorted { ($0.endTime - $0.startTime) > ($1.endTime - $1.startTime) }
            .prefix(count).map { $0 }
    }

    /// Named participants joined for list subtitles; nil until someone is
    /// named (callers fall back to `themName`).
    var participantsSummary: String? {
        let named = otherSpeakerLabels.compactMap { speakerNames[$0] }
        return named.isEmpty ? nil : named.joined(separator: ", ")
    }

    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
