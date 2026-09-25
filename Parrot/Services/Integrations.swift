import CryptoKit
import EventKit
import Foundation

// MARK: - Apple Reminders

/// Next steps → Apple Reminders, in a "Parrot" list. Local (EventKit), asked
/// for only when the user clicks the button the first time.
@MainActor
final class RemindersService {
    enum Failure: LocalizedError {
        case denied, noSource
        var errorDescription: String? {
            switch self {
            case .denied: "Parrot isn't allowed to add reminders. Allow it under Privacy & Security → Reminders."
            case .noSource: "No reminders account found on this Mac."
            }
        }
    }

    private let store = EKEventStore()
    static let listName = "Parrot"

    /// Adds one reminder per item; returns how many were added.
    func add(_ items: [String], from meetingTitle: String) async throws -> Int {
        guard !items.isEmpty else { return 0 }
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        guard granted else { throw Failure.denied }
        let list = try parrotList()
        for item in items {
            let reminder = EKReminder(eventStore: store)
            reminder.title = String(item.prefix(300))
            reminder.notes = "From “\(meetingTitle)” in Parrot"
            reminder.calendar = list
            try store.save(reminder, commit: false)
        }
        try store.commit()
        return items.count
    }

    private func parrotList() throws -> EKCalendar {
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == Self.listName }) {
            return existing
        }
        guard let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .local || $0.sourceType == .calDAV })
        else { throw Failure.noSource }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = Self.listName
        list.source = source
        try store.saveCalendar(list, commit: true)
        return list
    }
}

// MARK: - Export folder (Obsidian vault, Notes folder…)

/// A folder the user picked once; every finished meeting can be written
/// there as Markdown. Remembered with a security-scoped bookmark, so the
/// sandbox grants access to that folder only.
enum ExportFolder {
    static let bookmarkKey = "exportFolderBookmark"
    static let autoKey = "exportFolderAuto"
    /// Meeting id → the note's filename at its last save, so a renamed
    /// meeting moves its note instead of leaving the old one behind.
    static let namesKey = "exportFolderNames"

    static func set(_ url: URL) throws {
        let data = try url.bookmarkData(options: .withSecurityScope,
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: namesKey)
        UserDefaults.standard.set(false, forKey: autoKey)
    }

    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale { try? set(url) }
        return url
    }

    /// Writes (or rewrites) the meeting's note in the folder.
    @MainActor
    @discardableResult
    static func write(_ meeting: Meeting) throws -> URL {
        guard let folder = resolve() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Pick a folder in Settings → Connections first."])
        }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let name = ExportService.markdownFilename(for: meeting)
        let url = folder.appendingPathComponent(name)
        var names = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        let key = meeting.id.uuidString
        if let old = names[key], old != name {
            let oldURL = folder.appendingPathComponent(old)
            let fm = FileManager.default
            if fm.fileExists(atPath: oldURL.path), !fm.fileExists(atPath: url.path) {
                try? fm.moveItem(at: oldURL, to: url)
            }
        }
        try ExportService.exportToMarkdown(meeting: meeting).write(to: url, atomically: true, encoding: .utf8)
        names[key] = name
        UserDefaults.standard.set(names, forKey: namesKey)
        return url
    }
}

// MARK: - Webhook (Zapier, Make, n8n…)

/// Refuses every redirect for the one request it's attached to.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// After a call, POST the meeting as JSON to a URL the user pasted — the
/// bridge to Slack, Notion or a CRM through Zapier/Make/n8n. HTTPS only
/// (plain http just for localhost), optional HMAC signature, never sent
/// for an on-device-only meeting.
enum Webhook {
    static let urlKey = "webhookURL"
    static let enabledKey = "webhookEnabled"
    static let includeTranscriptKey = "webhookIncludeTranscript"
    static let secretAccount = "webhook-secret"
    static let lastResultKey = "webhookLastResult"

    /// A URL we'll send to, or nil.
    static func validate(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) { return url }
        return nil
    }

    /// The JSON body. Keys sorted, so a receiver can verify the signature
    /// over exactly these bytes.
    @MainActor
    static func payload(for meeting: Meeting, includeTranscript: Bool, now: Date = .now) -> Data {
        let iso = ISO8601DateFormatter()
        var m: [String: Any] = [
            "id": meeting.id.uuidString,
            "title": meeting.title,
            "date": iso.string(from: meeting.date),
            "duration_seconds": Int(meeting.duration),
            "people": meeting.attendees.map { ["name": $0.displayName, "email": $0.email ?? ""] },
            "summary": meeting.summary ?? "",
            "coaching": meeting.coaching ?? "",
            "next_steps": LastCallBrief.openItems(summary: meeting.summary, coaching: meeting.coaching, limit: 20),
            "bookmarks": meeting.bookmarks.map { ["time": Receipts.stamp($0.time), "label": $0.label] },
            "notes": meeting.notes,
        ]
        if let profile = meeting.profile?.name { m["profile"] = profile }
        if let consent = meeting.consent { m["consent"] = consent.summary }
        if includeTranscript {
            m["transcript"] = meeting.sortedSegments.map {
                ["time": $0.formattedTimestamp,
                 "speaker": meeting.displayName(forSpeaker: $0.speakerLabel),
                 "text": $0.text]
            }
        }
        let body: [String: Any] = ["event": "meeting.finished", "sent_at": iso.string(from: now), "meeting": m]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// "sha256=<hex>" of HMAC-SHA256(secret, body), sent as X-Parrot-Signature.
    static func signature(body: Data, secret: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        return "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    static func send(_ meeting: Meeting) async throws {
        guard CloudGate.mayLeaveMac(meeting), !CloudGate.forcesLocal else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "This meeting is on-device only, so it isn't sent."])
        }
        guard let url = validate(UserDefaults.standard.string(forKey: urlKey) ?? "") else {
            throw URLError(.badURL)
        }
        let body = payload(for: meeting, includeTranscript: UserDefaults.standard.bool(forKey: includeTranscriptKey))
        try await post(body, to: url)
    }

    /// A sample payload, to wire up the other end.
    static func sendTest() async throws {
        guard let url = validate(UserDefaults.standard.string(forKey: urlKey) ?? "") else {
            throw URLError(.badURL)
        }
        let body = (try? JSONSerialization.data(withJSONObject: [
            "event": "test", "sent_at": ISO8601DateFormatter().string(from: .now),
            "message": "Hello from Parrot. Real calls arrive as event \"meeting.finished\".",
        ], options: [.sortedKeys])) ?? Data()
        try await post(body, to: url)
    }

    private static func post(_ body: Data, to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Parrot", forHTTPHeaderField: "User-Agent")
        if let secret = APIKeyStore.load(account: secretAccount), !secret.isEmpty {
            request.setValue(signature(body: body, secret: secret), forHTTPHeaderField: "X-Parrot-Signature")
        }
        request.httpBody = body
        // No redirects: a 307/308 would re-send the whole meeting to wherever
        // it points, plain http or another host, past `validate`. The 3xx
        // shows up as a failure instead.
        let (_, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects())
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let result = (200..<300).contains(code) ? "Sent (\(code))" : "Failed (HTTP \(code))"
        UserDefaults.standard.set("\(result), \(Date.now.formatted(date: .abbreviated, time: .shortened))",
                                  forKey: lastResultKey)
        guard (200..<300).contains(code) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "The webhook answered HTTP \(code)."])
        }
    }
}
