import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings → Knowledge: documents in folders. A folder's Use for decides
/// which calls the Assistant may quote its documents on; a document can have
/// its own. The rule itself lives in `KnowledgeBaseService.isInPlay`.
struct KnowledgeSettingsView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Query(sort: \CallProfile.sortOrder) private var profiles: [CallProfile]
    @State private var search = ""
    @State private var importing = false
    /// The folder the file picker adds into (nil = No folder).
    @State private var importFolder: UUID?
    @State private var deleting: KBFolder?
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    /// Closed folders, comma-separated ids ("none" = No folder).
    @AppStorage("knowledgeClosedFolders") private var closedRaw = ""

    private var kb: KnowledgeBaseService { recordingManager.knowledgeBase }
    private var closed: Set<String> { Set(closedRaw.split(separator: ",").map(String.init)) }

    var body: some View {
        SettingsPage {
            SettingsCard(
                title: "Documents",
                blurb: "The Assistant grounds its answers in these and cites the source. Indexed on this Mac, never uploaded."
            ) {
                SettingsRow(first: true) { toolbar }
                if kb.isIndexing || kb.lastError != nil {
                    SettingsRow { status }
                }
                if kb.documents.isEmpty && kb.folders.isEmpty {
                    SettingsRow {
                        Text("No documents yet. Add a pricing sheet or an FAQ and the Assistant can quote it.")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Colors.ink3)
                    }
                }
                ForEach(kb.folders) { folder in
                    let docs = kb.documents(in: folder.id).filter { KnowledgeList.matches($0, search) }
                    if search.isEmpty || !docs.isEmpty {
                        section(folder, docs: docs)
                    }
                }
                let loose = kb.documents(in: nil).filter { KnowledgeList.matches($0, search) }
                if !loose.isEmpty {
                    section(nil, docs: loose)
                }
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.pdf, .plainText, .text],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                let folder = importFolder
                Task { await kb.addDocuments(at: urls, into: folder) }
            }
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { folder in
            Button("Delete folder", role: .destructive) { kb.deleteFolder(folder) }
        } message: { folder in
            Text(KnowledgeList.deleteMessage(count: kb.documents(in: folder.id).count))
        }
    }

    private var toolbar: some View {
        HStack(spacing: Theme.Metrics.controlGap) {
            TextField("Search documents", text: $search)
                .textFieldStyle(.roundedBorder)
            Button("New folder") {
                let folder = kb.createFolder(name: "New folder")
                renameText = folder.name
                renamingID = folder.id
            }
            Button("Add documents…") {
                importFolder = nil
                importing = true
            }
        }
    }

    private var status: some View {
        HStack(spacing: Theme.Metrics.controlGap) {
            if kb.isIndexing {
                ProgressView().controlSize(.small)
                Text("Embedding on this Mac…")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            if let error = kb.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.warn)
            }
        }
    }

    /// A folder header (nil = No folder) and, when open, its documents.
    @ViewBuilder
    private func section(_ folder: KBFolder?, docs: [KBDocument]) -> some View {
        let key = folder?.id.uuidString ?? "none"
        let open = !search.isEmpty || !closed.contains(key)
        let paused = folder?.scope == .off
        SettingsRow(tint: Theme.Colors.panel) {
            HStack(spacing: 8) {
                Button {
                    closedRaw = KnowledgeList.toggled(key, in: closedRaw)
                } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Close folder" : "Open folder")
                Image(systemName: folder == nil ? "tray" : "folder")
                    .foregroundStyle(paused ? Theme.Colors.ink3 : Theme.Colors.ink2)
                if let folder, renamingID == folder.id {
                    TextField("Folder name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.cardTitle)
                        .focused($renameFocused)
                        .onAppear { renameFocused = true }
                        .onSubmit { commitRename(folder) }
                        .onExitCommand { renamingID = nil }
                        .onChange(of: renameFocused) { _, focused in
                            if !focused, renamingID == folder.id { commitRename(folder) }
                        }
                } else {
                    Text(folder?.name ?? "No folder")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(paused ? Theme.Colors.ink2 : Theme.Colors.ink)
                        .lineLimit(1)
                }
                Text(docs.count == 1 ? "1 document" : "\(docs.count) documents")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)
                Spacer(minLength: 8)
                if let folder {
                    ScopeMenu(own: folder.scope, inherited: nil, profiles: profiles) {
                        kb.setScope($0 ?? .all, for: folder)
                    }
                    Menu {
                        Button("Rename") {
                            renameText = folder.name
                            renamingID = folder.id
                        }
                        Button("Add documents here…") {
                            importFolder = folder.id
                            importing = true
                        }
                        Divider()
                        Button("Delete folder…", role: .destructive) { deleting = folder }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Folder actions")
                } else {
                    Text("All call types")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink3)
                }
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            for id in ids.compactMap(UUID.init(uuidString:)) {
                if let document = kb.documents.first(where: { $0.id == id }) {
                    kb.move(document, to: folder?.id)
                }
            }
            return true
        }
        if open {
            ForEach(docs) { document in
                SettingsRow {
                    KBDocumentRow(document: document, folders: kb.folders, profiles: profiles, knowledgeBase: kb)
                }
            }
        }
    }

    private func commitRename(_ folder: KBFolder) {
        kb.renameFolder(folder, to: renameText)
        renamingID = nil
    }
}

// MARK: - Document row

/// One document: name, Use for, size and menu, with the About line under it.
struct KBDocumentRow: View {
    let document: KBDocument
    let folders: [KBFolder]
    let profiles: [CallProfile]
    let knowledgeBase: KnowledgeBaseService

    @State private var about: String
    @FocusState private var editingAbout: Bool
    /// Removal asks first: a document is work the user prepared.
    @State private var confirmingRemove = false

    init(document: KBDocument, folders: [KBFolder], profiles: [CallProfile], knowledgeBase: KnowledgeBaseService) {
        self.document = document
        self.folders = folders
        self.profiles = profiles
        self.knowledgeBase = knowledgeBase
        _about = State(initialValue: document.note)
    }

    private var inherited: KBScope { folders.first { $0.id == document.folderID }?.scope ?? .all }
    private var unused: Bool {
        KnowledgeList.pill(own: document.scope, inherited: inherited, profiles: profiles) == .notUsed
    }
    private var isPDF: Bool { document.name.lowercased().hasSuffix(".pdf") }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: isPDF ? "doc.richtext" : "doc.text")
                    .foregroundStyle(unused ? Theme.Colors.ink3 : Theme.Colors.accent)
                Text(document.displayName)
                    .font(Theme.Typography.sans(13, .medium))
                    .foregroundStyle(unused ? Theme.Colors.ink2 : Theme.Colors.ink)
                    .lineLimit(1)
                    .help(document.name)
                Spacer(minLength: 8)
                ScopeMenu(own: document.scope, inherited: inherited, profiles: profiles) {
                    knowledgeBase.setScope($0, for: document)
                }
                Text("\(document.chunkCount) chunks")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)
                    .monospacedDigit()
                    .lineLimit(1)
                Menu {
                    Menu("Move to folder") {
                        ForEach(folders) { folder in
                            Button(folder.name) { knowledgeBase.move(document, to: folder.id) }
                                .disabled(folder.id == document.folderID)
                        }
                        Divider()
                        Button("No folder") { knowledgeBase.move(document, to: nil) }
                            .disabled(document.folderID == nil)
                    }
                    Button("Edit about line") { editingAbout = true }
                    Divider()
                    Button("Remove…", role: .destructive) { confirmingRemove = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Document actions")
            }
            .contentShape(Rectangle())
            .draggable(document.id.uuidString)
            TextField("Add a line about this document", text: $about)
                .textFieldStyle(.plain)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
                .focused($editingAbout)
                .onSubmit { saveAbout() }
                .onChange(of: editingAbout) { _, editing in if !editing { saveAbout() } }
                .padding(.leading, 24)
        }
        .confirmationDialog("Remove \(document.displayName)?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive) { knowledgeBase.removeDocument(document) }
        } message: {
            Text("The Assistant stops using it right away. You can add the file again any time.")
        }
    }

    private func saveAbout() {
        if about != document.note { knowledgeBase.updateNote(about, for: document) }
    }
}

// MARK: - Use for pill and menu

/// The Use for pill and its menu. Folders pass `inherited: nil`; documents
/// pass their folder's scope (No folder: `.all`).
private struct ScopeMenu: View {
    let own: KBScope?
    let inherited: KBScope?
    let profiles: [CallProfile]
    let set: (KBScope?) -> Void

    private var effective: KBScope { own ?? inherited ?? .all }

    var body: some View {
        Menu {
            if inherited != nil {
                Toggle("Same as folder", isOn: choice(own == nil) { set(nil) })
                Divider()
            }
            Toggle("All call types", isOn: choice(own == .all) { set(.all) })
            Divider()
            ForEach(profiles) { profile in
                Toggle(profile.name, isOn: choice(ticked(profile.id)) {
                    // From Same as folder this starts from the folder's set.
                    set(effective.toggling(profile.id))
                })
            }
            Divider()
            Toggle("Off, not used on calls", isOn: choice(own == .off) { set(.off) })
        } label: {
            ScopePill(pill: KnowledgeList.pill(own: own, inherited: inherited, profiles: profiles))
        }
        // .button + .plain keeps the pill's own look (borderless flattens it).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Which calls the Assistant may use this on")
    }

    private func ticked(_ id: UUID) -> Bool {
        if case .only(let ids) = effective { return ids.contains(id) }
        return false
    }

    /// A menu checkmark that runs `action` when picked.
    private func choice(_ isOn: Bool, _ action: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { isOn }, set: { _ in action() })
    }
}

private struct ScopePill: View {
    let pill: KnowledgeList.Pill

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
            Image(systemName: "chevron.down")
        }
        .font(Theme.Typography.caption)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, Theme.Metrics.tagInsetH)
        .padding(.vertical, Theme.Metrics.tagInsetV)
        .foregroundStyle(foreground)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Metrics.chipRadius))
        .overlay {
            if dashed {
                RoundedRectangle(cornerRadius: Theme.Metrics.chipRadius)
                    .strokeBorder(Theme.Colors.line, style: StrokeStyle(lineWidth: 1, dash: Theme.Metrics.offDash))
            }
        }
        .contentShape(Rectangle())
    }

    private var text: String {
        switch pill {
        case .sameAsFolder: "Same as folder"
        case .allTypes: "All call types"
        case .types(let names, _): names.count <= 2 ? names.joined(separator: ", ") : "\(names[0]) +\(names.count - 1)"
        case .notUsed: "Not used on calls"
        case .paused: "Off"
        }
    }

    private var icon: String? {
        switch pill {
        case .notUsed: "eye.slash"
        case .paused: "pause.fill"
        default: nil
        }
    }

    private var dashed: Bool { pill == .notUsed || pill == .paused }

    private var highlighted: Bool {
        switch pill {
        case .allTypes(let own), .types(_, let own): own
        default: false
        }
    }

    private var foreground: Color { dashed ? Theme.Colors.ink3 : highlighted ? Theme.Colors.accent : Theme.Colors.ink2 }
    private var background: Color { dashed ? .clear : highlighted ? Theme.Colors.selection : Theme.Colors.chip }
}

// MARK: - Pure helpers

/// The Knowledge page's decisions, kept pure for --profile-test.
enum KnowledgeList {
    /// What a Use for pill says.
    enum Pill: Equatable {
        case sameAsFolder
        case allTypes(own: Bool)
        case types([String], own: Bool)
        case notUsed
        case paused
    }

    /// Documents pass their folder's scope (No folder: `.all`) as
    /// `inherited`; folders pass nil. Deleted call types are ignored.
    static func pill(own: KBScope?, inherited: KBScope?, profiles: [CallProfile]) -> Pill {
        let isDocument = inherited != nil
        let effective = own ?? inherited ?? .all
        switch effective {
        case .off:
            return isDocument ? .notUsed : .paused
        case .only(let ids):
            let names = profiles.filter { ids.contains($0.id) }.map(\.name)
            if names.isEmpty { return .notUsed }
            return isDocument && own == nil ? .sameAsFolder : .types(names, own: isDocument)
        case .all:
            return isDocument && own == nil ? .sameAsFolder : .allTypes(own: isDocument)
        }
    }

    /// Search: name or About line, ignoring case and accents.
    static func matches(_ document: KBDocument, _ query: String) -> Bool {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        return q.isEmpty || fold(document.name).contains(q) || fold(document.note).contains(q)
    }

    /// Lowercase, no accents, Turkish ı/İ as plain i/I ("Çalışma" →
    /// "calisma"). A fixed locale, so a Turkish Mac doesn't fold "I" to "ı".
    private static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "İ", with: "I")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func deleteMessage(count: Int) -> String {
        switch count {
        case 0: "It's empty."
        case 1: "Its document moves to No folder and keeps its settings."
        default: "Its \(count) documents move to No folder and keep their settings."
        }
    }

    /// Opens or closes one folder in the stored set ("none" = No folder).
    static func toggled(_ key: String, in raw: String) -> String {
        var keys = Set(raw.split(separator: ",").map(String.init))
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        return keys.sorted().joined(separator: ",")
    }
}
