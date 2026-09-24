import EventKit
import Foundation

/// Someone on a calendar invite.
struct Attendee: Codable, Hashable {
    var name: String
    var email: String?

    /// "Jeremy Smith" → "Jeremy Smith"; an email-only guest → the email's
    /// local part, so the naming UI has something human to offer.
    var displayName: String {
        if !name.isEmpty { return name }
        return email.map { String($0.split(separator: "@").first ?? Substring($0)) } ?? ""
    }
}

/// A calendar event, reduced to what Parrot uses. A plain value so the
/// matching and cleaning logic below is testable without EventKit.
struct CalendarEventInfo: Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool = false
    var notes: String = ""
    var attendees: [Attendee] = []
    /// The user declined this invite.
    var declined: Bool = false
    /// The event carries a video link (Zoom/Meet/Teams URL) — a call, not a
    /// focus block or a lunch.
    var hasCallLink: Bool = false
}

/// Reads the Mac's own calendars through EventKit — whatever the Calendar
/// app already syncs (iCloud, Google, Outlook/Exchange). No sign-in, no
/// network, read-only, and only after the user clicks Connect.
@MainActor
@Observable
final class CalendarService {

    enum Access: Equatable {
        case notAsked, granted, denied
    }

    nonisolated static let enabledKey = "calendarEnabled"
    nonisolated static let useDetailsKey = "calendarUseDetails"
    nonisolated static let remindersKey = "calendarReminders"

    private(set) var access: Access = CalendarService.currentAccess()
    @ObservationIgnored private let store = EKEventStore()

    /// Connected = the user turned it on AND macOS granted access.
    var isConnected: Bool {
        access == .granted && UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    nonisolated static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notAsked
        default: return .denied   // denied, restricted, write-only
        }
    }

    /// Asks macOS for read access (the one system prompt) and turns the
    /// integration on when granted.
    @discardableResult
    func connect() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        access = granted ? .granted : Self.currentAccess()
        if granted {
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            store.reset()   // pick up calendars now visible to this store
        }
        return granted
    }

    func disconnect() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
    }

    func refreshAccess() {
        access = Self.currentAccess()
    }

    /// Events overlapping [from, to], reduced to `CalendarEventInfo`.
    func events(from: Date, to: Date) -> [CalendarEventInfo] {
        guard isConnected else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).map(Self.info(from:))
    }

    /// The event this call most likely belongs to (see `pickCurrent`).
    func currentEvent(now: Date = .now) -> CalendarEventInfo? {
        let lead = Self.matchLead
        return Self.pickCurrent(events(from: now.addingTimeInterval(-6 * 3600),
                                       to: now.addingTimeInterval(lead)), now: now)
    }

    private static func info(from event: EKEvent) -> CalendarEventInfo {
        let people = (event.attendees ?? []).filter {
            !$0.isCurrentUser && $0.participantType == .person
        }
        let declined = (event.attendees ?? []).contains {
            $0.isCurrentUser && $0.participantStatus == .declined
        }
        let text = [event.location, event.notes, event.url?.absoluteString]
            .compactMap { $0 }.joined(separator: "\n")
        return CalendarEventInfo(
            id: event.calendarItemIdentifier,
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            notes: event.notes ?? "",
            attendees: people.map { Attendee(name: $0.name ?? "", email: Self.email(from: $0.url)) },
            declined: declined,
            hasCallLink: Self.containsCallLink(text)
        )
    }

    // MARK: - Pure logic (harness-covered)

    /// How early a call may start and still match its event (joining a few
    /// minutes before the hour is normal).
    nonisolated static let matchLead: TimeInterval = 10 * 60

    /// The event a call starting at `now` belongs to: timed (not all-day),
    /// not declined, running now or starting within `matchLead`. Among
    /// several, prefer one with a video link, then one with attendees, then
    /// the one whose start is nearest.
    nonisolated static func pickCurrent(_ events: [CalendarEventInfo], now: Date) -> CalendarEventInfo? {
        let candidates = events.filter {
            !$0.isAllDay && !$0.declined
                && $0.start.addingTimeInterval(-matchLead) <= now && now < $0.end
        }
        return candidates.min { a, b in
            if a.hasCallLink != b.hasCallLink { return a.hasCallLink }
            if a.attendees.isEmpty != b.attendees.isEmpty { return !a.attendees.isEmpty }
            return abs(a.start.timeIntervalSince(now)) < abs(b.start.timeIntervalSince(now))
        }
    }

    /// Events starting within `window` after `now` that haven't been
    /// reminded about yet — for "starts in a minute" notifications.
    nonisolated static func dueReminders(_ events: [CalendarEventInfo], now: Date, window: TimeInterval = 60,
                             alreadyReminded: Set<String>) -> [CalendarEventInfo] {
        events.filter {
            !$0.isAllDay && !$0.declined && !alreadyReminded.contains($0.id)
                && $0.start > now && $0.start.timeIntervalSince(now) <= window
                && ($0.hasCallLink || !$0.attendees.isEmpty)
        }
    }

    nonisolated static func email(from url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "mailto" else { return nil }
        let raw = url.absoluteString.dropFirst("mailto:".count)
        let address = raw.split(separator: "?").first.map(String.init) ?? String(raw)
        return address.removingPercentEncoding ?? address
    }

    nonisolated static func containsCallLink(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["zoom.us/", "meet.google.com/", "teams.microsoft.com/", "teams.live.com/",
                "webex.com/", "whereby.com/", "around.co/", "facetime.apple.com/", "chime.aws/"]
            .contains { t.contains($0) }
    }

    /// Event notes minus the dial-in boilerplate video tools paste in:
    /// links, meeting IDs, passcodes, phone numbers, separator lines.
    /// What's left is what a person wrote ("Agenda: renewal, legal Qs").
    nonisolated static func cleanNotes(_ notes: String, limit: Int = 400) -> String {
        // Some calendars store notes as HTML.
        let plain = notes
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let boilerplate = ["http://", "https://", "meeting id", "passcode", "password", "dial", "join ",
                           "join:", "one tap", "tel:", "pin:", "meeting number", "access code",
                           "find your local number", "microsoft teams", "zoom meeting", "google meet",
                           "click here", "learn more", "meeting options", "conference id", "─", "———",
                           "-::~:~::", "please do not edit"]
        let kept = plain.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let l = line.lowercased()
                if boilerplate.contains(where: { l.contains($0) }) { return false }
                // Lines that are mostly digits/punctuation (phone numbers, IDs).
                let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
                return letters * 2 >= line.count
            }
        let joined = kept.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard joined.count > limit else { return joined }
        let cut = joined.prefix(limit)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    /// What the copilot may read about the invite: title, guests, and any
    /// notes a person wrote. Angle brackets are neutralised so invite text
    /// can't close the <calendar_invite> delimiter it's carried in. Empty
    /// when there's nothing useful.
    nonisolated static func inviteContext(for event: CalendarEventInfo, maxAttendees: Int = 8) -> String {
        func safe(_ s: String) -> String {
            s.replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
        }
        var lines: [String] = []
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { lines.append("Title: \(safe(String(title.prefix(200))))") }
        let names = event.attendees.map(\.displayName).filter { !$0.isEmpty }
        if !names.isEmpty {
            let shown = names.prefix(maxAttendees).map { safe(String($0.prefix(80))) }.joined(separator: ", ")
            let more = names.count > maxAttendees ? " and \(names.count - maxAttendees) more" : ""
            lines.append("Guests: \(shown)\(more)")
        }
        let notes = cleanNotes(event.notes)
        if !notes.isEmpty { lines.append("Notes: \(safe(notes))") }
        return lines.joined(separator: "\n")
    }

    /// Words in an event title that point at a built-in profile. Matched
    /// against the user's profile names too, so a custom "Board update"
    /// profile catches "Q3 board update".
    nonisolated static let profileHints: [(keywords: [String], profileWords: [String])] = [
        (["interview", "candidate", "screening"], ["interview"]),
        (["1:1", "1-1", "one on one", "one-on-one", "coaching", "mentoring"], ["coaching", "1:1"]),
        (["demo", "discovery", "sales", "prospect", "pitch"], ["sales"]),
        (["support", "escalation", "ticket", "onboarding"], ["support"]),
        (["vendor", "supplier", "procurement"], ["vendor"]),
    ]

    /// The profile an event title points at, or nil when nothing matches
    /// or more than one profile does (ambiguous → keep the user's choice).
    nonisolated static func matchProfile(title: String, profiles: [(id: UUID, name: String)]) -> UUID? {
        let t = " " + title.lowercased() + " "
        var hits = Set<UUID>()
        for profile in profiles {
            let name = profile.name.lowercased()
            // A profile named in the title ("Sales discovery w/ Acme").
            if name.count >= 4, t.contains(name) { hits.insert(profile.id); continue }
            for hint in profileHints where hint.keywords.contains(where: { t.contains($0) }) {
                if hint.profileWords.contains(where: { name.contains($0) }) { hits.insert(profile.id) }
            }
        }
        return hits.count == 1 ? hits.first : nil
    }
}
