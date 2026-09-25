import SwiftUI
import SwiftData

/// Ask Parrot's page: saved chats beside the conversation. Every answer
/// cites the moment it came from; the header says which AI writes it.
struct AskPageView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSession.self) private var appSession
    @Environment(\.openSettings) private var openSettings
    @Query private var meetings: [Meeting]
    @AppStorage("askProvider") private var askProvider = ""

    @State private var selectedID: UUID?
    /// A new chat that has no messages yet (not saved until the first one).
    @State private var draft: AskChat?
    @State private var question = ""
    @State private var running: Task<Void, Never>?
    @State private var stage: String?
    /// Identifies the in-flight turn: stop() clears this, so a task that
    /// unwinds after a new turn started can't touch the new turn's
    /// stage/running state or save its answer into it.
    @State private var turn: UUID?
    @State private var renaming: AskChat?
    @State private var renameText = ""
    @FocusState private var focused: Bool

    static let examples = [
        "What did I promise to send, and to whom?",
        "What objections came up about pricing?",
        "What did we decide about the timeline?",
    ]

    private var store: AskChatStore { recordingManager.chats }
    private var chat: AskChat? { draft ?? selectedID.flatMap { store.chat($0) } }
    private var switching: SwitchingAnalysisProvider? {
        recordingManager.callAnalysisEngine.provider as? SwitchingAnalysisProvider
    }

    var body: some View {
        HStack(spacing: 0) {
            chatList
                .frame(width: Theme.Metrics.chatListWidth)
            Divider()
            conversation
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Colors.canvas)
        .onAppear(perform: takeRequest)
        .onChange(of: appSession.askRequest) { _, _ in takeRequest() }
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let r = renaming { store.rename(r.id, to: renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    // MARK: Chat list

    private var chatList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { startNew(scope: nil, scopeTitle: nil) } label: {
                Label("New chat", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(AskChatStore.grouped(store.chats, now: .now), id: \.label) { group in
                        Text(group.label)
                            .textCase(.uppercase)
                            .font(Theme.Typography.cap)
                            .foregroundStyle(Theme.Colors.ink3)
                            .padding(.horizontal, Theme.Metrics.chipInsetH)
                            .padding(.top, Theme.Metrics.popoverPad)
                        ForEach(group.chats) { row($0) }
                    }
                }
            }
        }
        .padding(Theme.Metrics.popoverPad)
        .background(Theme.Colors.panel)
    }

    private func row(_ c: AskChat) -> some View {
        let selected = draft == nil && selectedID == c.id
        return Button { select(c.id) } label: {
            Text(c.title)
                .font(Theme.Typography.body)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Metrics.chipInsetH)
                .padding(.vertical, Theme.Metrics.bannerInsetV / 2)
                .background(selected ? Theme.Colors.selection : Color.clear,
                            in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") { renameText = c.title; renaming = c }
            Button("Delete", role: .destructive) {
                if selectedID == c.id { stopIfRunning(); selectedID = nil }
                store.delete(c.id)
                takeRequest()
            }
        }
    }

    // MARK: Conversation

    @ViewBuilder
    private var conversation: some View {
        if let chat {
            VStack(spacing: 0) {
                header(chat)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Metrics.sectionGap / 2) {
                            if chat.messages.isEmpty { examples }
                            ForEach(chat.messages) { message($0).id($0.id) }
                            if let stage {
                                HStack(spacing: Theme.Metrics.chipInsetH * 1.5) {
                                    ParrotAvatar()
                                    ProgressView().controlSize(.small)
                                    Text(stage)
                                        .font(Theme.Typography.secondary)
                                        .foregroundStyle(Theme.Colors.ink2)
                                }
                                .id("stage")
                            }
                        }
                        .padding(Theme.Metrics.pad)
                        .frame(maxWidth: Theme.Metrics.chatMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: chat.messages.count) { _, _ in
                        withAnimation { proxy.scrollTo(chat.messages.last?.id, anchor: .bottom) }
                    }
                    .onChange(of: stage) { _, s in
                        if s != nil { withAnimation { proxy.scrollTo("stage", anchor: .bottom) } }
                    }
                }
                input(chat)
            }
        }
    }

    private func header(_ chat: AskChat) -> some View {
        HStack(spacing: Theme.Metrics.controlGap) {
            Text(chat.messages.isEmpty ? "New chat" : chat.title)
                .font(Theme.Typography.title(15))
                .lineLimit(1)
            if chat.scope != nil, let title = chat.scopeTitle {
                HStack(spacing: 4) {
                    Text("This meeting: \(title)").lineLimit(1)
                    Button { widen() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("Search all meetings")
                }
                .font(Theme.Typography.caption)
                .padding(.horizontal, Theme.Metrics.chipInsetH)
                .padding(.vertical, Theme.Metrics.chipInsetV)
                .background(Theme.Colors.chip, in: Capsule())
            }
            Spacer()
            aiMenu
        }
        .padding(.horizontal, Theme.Metrics.pad)
        .padding(.vertical, Theme.Metrics.bannerInsetV)
    }

    private var aiMenu: some View {
        Menu {
            Picker("Ask Parrot uses", selection: $askProvider) {
                Text("Same as reports").tag("")
                ForEach(CopilotProviderKind.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("AI Settings…") { SettingsView.open(.copilot, with: openSettings) }
        } label: {
            Label(label(for: askProvider), systemImage: "sparkles")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which AI writes the answers")
    }

    /// Takes the setting so the label re-renders when the choice changes.
    private func label(for setting: String) -> String { switching?.askModelLabel ?? "AI" }

    @ViewBuilder
    private func message(_ m: AskMessage) -> some View {
        switch m.role {
        case .me:
            HStack {
                Spacer(minLength: Theme.Metrics.chatListWidth / 3)
                Text(m.text)
                    .font(Theme.Typography.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, Theme.Metrics.bubbleInsetH)
                    .padding(.vertical, Theme.Metrics.bubbleInsetV)
                    .background(Theme.Colors.selection, in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius))
            }
        case .parrot:
            HStack(alignment: .top, spacing: Theme.Metrics.chipInsetH * 1.5) {
                ParrotAvatar()
                AskAnswerView(message: m, existing: Set(meetings.map(\.id)), open: open)
            }
        }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try")
                .font(Theme.Typography.sectionLabel)
                .foregroundStyle(Theme.Colors.label)
            ForEach(Self.examples, id: \.self) { example in
                Button(example) {
                    question = example
                    send()
                }
                .buttonStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.accent)
            }
        }
    }

    private func input(_ chat: AskChat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: Theme.Metrics.chipInsetH * 1.5) {
                TextField(chat.messages.isEmpty ? "Ask about your meetings…" : "Ask a follow-up…",
                          text: $question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.Typography.body)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit(send)
                if running != nil {
                    Button("Stop", action: stop)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Send", action: send)
                        .buttonStyle(.borderedProminent)
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Text(privacyLine)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Metrics.pad)
    }

    private var privacyLine: String {
        guard switching?.askConfigured == true else {
            return "Search runs on this Mac. Nothing is sent anywhere."
        }
        if switching?.askRunsLocally == true {
            return "Search runs on this Mac, and your local model writes the answer. Nothing leaves your Mac."
        }
        return "Search runs on this Mac. The few best passages and this chat's recent messages (never audio) go to your AI to write the answer."
    }

    // MARK: Actions

    /// A pending request (⌘K, menu, a meeting's Ask) starts a new chat;
    /// otherwise show the newest chat, or a new one.
    private func takeRequest() {
        if let request = appSession.askRequest {
            startNew(scope: request.scope, scopeTitle: request.scopeTitle)
            appSession.askRequest = nil
        } else if chat == nil {
            if let newest = store.chats.first { selectedID = newest.id }
            else { startNew(scope: nil, scopeTitle: nil) }
        }
    }

    private func startNew(scope: UUID?, scopeTitle: String?) {
        stopIfRunning()
        draft = AskChat(title: "New chat", scope: scope, scopeTitle: scopeTitle)
        selectedID = nil
        question = ""
        focused = true
    }

    private func select(_ id: UUID) {
        stopIfRunning()
        draft = nil
        selectedID = id
    }

    private func widen() {
        guard var c = chat else { return }
        c.scope = nil
        c.scopeTitle = nil
        if draft != nil { draft = c } else { store.upsert(c) }
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, running == nil, var c = chat else { return }
        let prior = c
        if c.messages.isEmpty { c.title = AskChatStore.title(for: q) }
        c.messages.append(AskMessage(role: .me, text: q))
        store.upsert(c)
        draft = nil
        selectedID = c.id
        question = ""
        let id = c.id
        let myTurn = UUID()
        turn = myTurn
        running = Task {
            let result = await recordingManager.ask(q, in: prior) { s in
                if turn == myTurn { stage = s }
            }
            guard turn == myTurn else { return }
            stage = nil
            running = nil
            guard !Task.isCancelled, var now = store.chat(id) else { return }
            now.messages.append(AskMessage(answer: result))
            store.upsert(now)
        }
    }

    /// Stop: the turn is not saved and the question goes back in the field.
    private func stop() {
        turn = nil
        running?.cancel()
        running = nil
        stage = nil
        guard let id = selectedID, var c = store.chat(id), let last = c.messages.last, last.role == .me else { return }
        c.messages.removeLast()
        question = last.text
        if c.messages.isEmpty {
            store.delete(c.id)
            draft = AskChat(title: "New chat", scope: c.scope, scopeTitle: c.scopeTitle)
            selectedID = nil
        } else {
            store.upsert(c)
        }
    }

    private func stopIfRunning() { if running != nil { stop() } }

    private func open(_ meetingID: UUID, at time: TimeInterval?) {
        appSession.pendingJump = AppSession.Jump(meetingID: meetingID, time: time)
    }
}
