import Foundation
import Observation

/// One message in an Ask Parrot chat. Parrot's answers keep their checked
/// lines and the meetings they cite, so chips still open the right moment.
struct AskMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case me, parrot }

    var id = UUID()
    var role: Role
    var text: String
    var lines: [AskEngine.Line] = []
    var refs: [AskEngine.MeetingRef] = []
    var note: String?
    var answeredByAI = false
    var usedPrivate = false
    var model: String?

    init(role: Role, text: String) {
        self.role = role
        self.text = text
    }

    init(answer: AskEngine.Result) {
        role = .parrot
        text = answer.lines.map(\.text).joined(separator: "\n")
        lines = answer.lines
        refs = answer.refs
        note = answer.note
        answeredByAI = answer.answeredByAI
        usedPrivate = answer.usedPrivate
        model = answer.model
    }
}

/// A saved conversation. `scope` limits it to one meeting.
struct AskChat: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var scope: UUID?
    var scopeTitle: String?
    var created: Date
    var updated: Date
    var messages: [AskMessage] = []

    init(title: String, scope: UUID?, scopeTitle: String?, now: Date = .now) {
        self.title = title
        self.scope = scope
        self.scopeTitle = scopeTitle
        created = now
        updated = now
    }
}

/// Saved Ask Parrot chats, one JSON file beside the search index. Not
/// SwiftData on purpose: no schema change, so an older build can't drop them.
@MainActor @Observable
final class AskChatStore {
    /// Newest activity first.
    private(set) var chats: [AskChat] = []
    @ObservationIgnored private let directory: URL?

    init(directory: URL? = AskChatStore.defaultDirectory) {
        self.directory = directory
        load()
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parrot/Chats", isDirectory: true)
    }

    private var fileURL: URL? { directory?.appendingPathComponent("chats.json") }

    func chat(_ id: UUID) -> AskChat? { chats.first { $0.id == id } }

    /// Inserts or replaces a chat, marks it active now, saves.
    func upsert(_ chat: AskChat, now: Date = .now) {
        var chat = chat
        chat.updated = now
        chats.removeAll { $0.id == chat.id }
        chats.append(chat)
        chats.sort { $0.updated > $1.updated }
        save()
    }

    func rename(_ id: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[i].title = String(clean.prefix(60))
        save()
    }

    func delete(_ id: UUID) {
        chats.removeAll { $0.id == id }
        save()
    }

    /// Clean-up: chats nobody touched for `days` go, like old meetings.
    @discardableResult
    func removeStale(olderThanDays days: Int, now: Date = .now) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let before = chats.count
        chats.removeAll { $0.updated < cutoff }
        if chats.count != before { save() }
        return before - chats.count
    }

    /// Dev-harness only (--help-shots): show chats without touching disk.
    func seedForSnapshot(_ chats: [AskChat]) { self.chats = chats }

    /// A chat's name: the first line of its first question, at most 60 characters.
    nonisolated static func title(for question: String) -> String {
        let first = question.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        return first.count > 60 ? String(first.prefix(59)) + "…" : first
    }

    /// Today / Yesterday / weekday (last 7 days) / "12 Sep", in list order.
    nonisolated static func grouped(_ chats: [AskChat], now: Date,
                                    calendar: Calendar = .current) -> [(label: String, chats: [AskChat])] {
        var out: [(label: String, chats: [AskChat])] = []
        for chat in chats {
            let label: String
            if calendar.isDate(chat.updated, inSameDayAs: now) {
                label = "Today"
            } else if let y = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(chat.updated, inSameDayAs: y) {
                label = "Yesterday"
            } else if let week = calendar.date(byAdding: .day, value: -7, to: now), chat.updated > week {
                var style = Date.FormatStyle().weekday(.wide)
                style.timeZone = calendar.timeZone
                label = chat.updated.formatted(style)
            } else {
                var style = Date.FormatStyle().day().month(.abbreviated)
                style.timeZone = calendar.timeZone
                label = chat.updated.formatted(style)
            }
            if out.last?.label == label { out[out.count - 1].chats.append(chat) }
            else { out.append((label, [chat])) }
        }
        return out
    }

    // MARK: Persistence

    private func load() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        do {
            chats = try JSONDecoder().decode([AskChat].self, from: data).sorted { $0.updated > $1.updated }
        } catch {
            // Never lose a file we can't read: keep it aside, start empty.
            let bad = url.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: url, to: bad)
            NSLog("Parrot: saved chats couldn't be read; kept as chats.json.bad")
        }
    }

    private func save() {
        guard let directory, let url = fileURL else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(chats) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
