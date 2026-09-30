import Foundation

/// What applying a `.parrotprofile` would change, grouped the way the review
/// screen shows it (persona, what to flag, report, mood meters, other).
/// Pure: built from two `ProfileFile.Profile` values, so imports, gallery
/// updates and Claude's suggestions all review the same way.
struct ProfileChanges: Equatable {
    struct Line: Equatable {
        let label: String
        let before: String
        let after: String
    }

    var persona: Line?
    var kindsAdded: [String] = []
    var kindsRemoved: [String] = []
    var kindsChanged: [String] = []
    /// Section titles (plus coaching) before and after, nil when unchanged.
    var report: (before: [String], after: [String])?
    var gaugesAdded: [String] = []
    var gaugesRemoved: [String] = []
    var gaugesChanged: [String] = []
    var other: [Line] = []
    /// The file turns on-device only on. Nothing can turn it off.
    var turnsOnDeviceOnly = false

    var isEmpty: Bool {
        persona == nil && kindsAdded.isEmpty && kindsRemoved.isEmpty && kindsChanged.isEmpty && report == nil
            && gaugesAdded.isEmpty && gaugesRemoved.isEmpty && gaugesChanged.isEmpty && other.isEmpty && !turnsOnDeviceOnly
    }

    static func == (a: ProfileChanges, b: ProfileChanges) -> Bool {
        a.persona == b.persona && a.kindsAdded == b.kindsAdded && a.kindsRemoved == b.kindsRemoved
            && a.kindsChanged == b.kindsChanged && a.report?.before == b.report?.before && a.report?.after == b.report?.after
            && a.gaugesAdded == b.gaugesAdded && a.gaugesRemoved == b.gaugesRemoved && a.gaugesChanged == b.gaugesChanged
            && a.other == b.other && a.turnsOnDeviceOnly == b.turnsOnDeviceOnly
    }

    /// `current` nil = a new profile: everything in the file is an addition.
    static func between(_ current: ProfileFile.Profile?, currentlyPrivate: Bool, and file: ProfileFile) -> ProfileChanges {
        let new = file.profile
        var c = ProfileChanges()
        c.turnsOnDeviceOnly = !currentlyPrivate && file.privacy?.recommendOnDeviceOnly == true
        let old = current

        if old?.persona != new.persona {
            c.persona = Line(label: "Persona", before: old?.persona ?? "", after: new.persona)
        }

        let oldKinds = Dictionary((old?.kinds ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let newKinds = Dictionary(new.kinds.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        c.kindsAdded = new.kinds.filter { oldKinds[$0.key] == nil }.map(\.label)
        c.kindsRemoved = (old?.kinds ?? []).filter { newKinds[$0.key] == nil }.map(\.label)
        c.kindsChanged = new.kinds.filter { k in oldKinds[k.key].map { $0 != k } ?? false }.map(\.label)

        let oldGauges = Dictionary((old?.gauges ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let newGauges = Dictionary(new.gauges.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        c.gaugesAdded = new.gauges.filter { oldGauges[$0.key] == nil }.map(\.label)
        c.gaugesRemoved = (old?.gauges ?? []).filter { newGauges[$0.key] == nil }.map(\.label)
        c.gaugesChanged = new.gauges.filter { g in oldGauges[g.key].map { $0 != g } ?? false }.map(\.label)

        // No report block means the classic report, word for word.
        let oldReport = old.map { $0.report ?? .standard }
        let newReport = new.report ?? .standard
        if oldReport != newReport {
            c.report = (oldReport.map(describe) ?? [], describe(newReport))
        }

        func line(_ label: String, _ a: String?, _ b: String) {
            if (a ?? "") != b { c.other.append(Line(label: label, before: a ?? "", after: b)) }
        }
        line("Name", old?.name, new.name)
        line("Summary", old?.summary, new.summary)
        line("Calls the other side", old?.counterpart, new.counterpart)
        line("Custom rules", old?.tone, new.tone)
        if old?.icon != new.icon && old != nil { c.other.append(Line(label: "Icon", before: old?.icon ?? "", after: new.icon)) }
        if let old, old.allowGeneralKnowledge != new.allowGeneralKnowledge {
            c.other.append(Line(label: "Answer from general knowledge",
                                before: old.allowGeneralKnowledge ? "On" : "Off", after: new.allowGeneralKnowledge ? "On" : "Off"))
        }
        return c
    }

    /// A report as its section titles, then what the coaching does.
    static func describe(_ t: ReportTemplate) -> [String] {
        t.sections.map { $0.type == "scorecard" ? "\($0.title) (scorecard)" : $0.title }
            + [t.coachingEnabled ? "Coaching: \(t.coachRole)" : "No coaching report"]
    }
}

/// A profile file waiting for the review screen: one the user opened or
/// dropped, or an AI app's suggestion from the inbox.
struct PendingProfile: Identifiable, Equatable {
    enum Origin: Equatable {
        /// Opened, dropped or imported: the file's name.
        case file(String)
        /// From the inbox; the file is deleted once the user decides.
        case suggestion(URL)
    }
    let id = UUID()
    let data: Data
    let origin: Origin

    /// Reads at most a byte over the limit, so a huge file is refused by
    /// `ProfileFile.decode` without ever being loaded whole.
    static func read(_ url: URL, origin: Origin? = nil) -> PendingProfile? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: ProfileFile.maxBytes + 1)) ?? Data()
        return PendingProfile(data: data, origin: origin ?? .file(url.lastPathComponent))
    }
}

/// Profiles AI apps suggested, waiting for the user in Parrot. The MCP
/// server (its own process) writes here; the app reads, reviews and deletes.
/// Files only: a suggestion never touches the profile store.
enum ProfileInbox {
    static let limit = 10

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Parrot/ProfileInbox", isDirectory: true)
    }

    /// Checks the file, then keeps it; the oldest go when there are more
    /// than `limit`. Throws the file's plain refusal reason.
    @discardableResult
    static func add(_ data: Data, in directory: URL = defaultDirectory) throws -> URL {
        _ = try ProfileFile.decode(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + ".parrotprofile")
        try data.write(to: url, options: .atomic)
        let all = pending(in: directory)
        for old in all.dropLast(limit) { try? FileManager.default.removeItem(at: old) }
        return url
    }

    /// Waiting files, oldest first.
    static func pending(in directory: URL = defaultDirectory) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "parrotprofile" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a == b ? $0.lastPathComponent < $1.lastPathComponent : a < b
        }
    }
}

/// Tells the app when an AI app leaves a suggestion. The MCP server is its
/// own process, so the inbox folder is the only channel: a directory watch,
/// plus a first scan for what arrived while Parrot was closed.
@MainActor
final class ProfileInboxWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var seen: Set<String> = []
    private var directory = ProfileInbox.defaultDirectory
    private var onNew: ([PendingProfile]) -> Void = { _ in }

    func start(directory: URL = ProfileInbox.defaultDirectory, onNew: @escaping ([PendingProfile]) -> Void) {
        stop()
        self.directory = directory
        self.onNew = onNew
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        scan()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    /// Files not handed over yet. A file the user has decided on is deleted,
    /// so `seen` only guards against one event firing twice.
    private func scan() {
        let fresh = ProfileInbox.pending(in: directory).filter { !seen.contains($0.lastPathComponent) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { seen.insert($0.lastPathComponent) }
        onNew(fresh.compactMap { PendingProfile.read($0, origin: .suggestion($0)) })
    }
}
