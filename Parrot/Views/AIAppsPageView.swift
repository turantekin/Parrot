import AppKit
import SwiftData
import SwiftUI

extension Notification.Name {
    /// Settings, the report tip and the banner open the Claude & AI Apps page.
    static let parrotOpenAIApps = Notification.Name("parrotOpenAIApps")
}

/// The pure half of the Claude & AI Apps page: wording and when things show.
/// Harness-covered; the views below only read and write defaults.
enum AIApps {

    static let bannerShownKey = "mcpBannerShown"
    static let v1CheckedKey = "mcpV1Checked"
    static let v1ConnectedKey = "mcpV1Connected"
    static let tipLastShownKey = "mcpTipLastShown"
    static let tipsOffKey = "mcpTipsOff"
    static let firstQuestion = "What did I promise last week?"

    struct Job: Identifiable {
        let title: String
        let examples: [String]
        var id: String { title }
    }

    /// What people can do, as jobs rather than a tool list.
    static let jobs: [Job] = [
        Job(title: "Find anything",
            examples: ["When did Sarah mention the budget?", "Which calls talked about the API?"]),
        Job(title: "Catch up",
            examples: ["Give me a digest of last week's meetings.", "Everything with Acme this quarter."]),
        Job(title: "Never drop a promise",
            examples: [firstQuestion, "What is the client waiting on from us?"]),
        Job(title: "Write it for me",
            examples: ["Draft a follow-up email for my last call with Acme.", "Turn today's calls into a Slack update."]),
        Job(title: "Second opinion",
            examples: ["Coach me across my last 10 calls: where do I talk too much?", "Redo my last sales call's report with MEDDIC."]),
        Job(title: "Prepare",
            examples: ["Brief me for my call with Acme in 10 minutes.", "What's still open with Sarah?"]),
        Job(title: "Tune my Copilot",
            examples: ["Improve my Sales discovery profile from my last 10 calls.",
                       "Make my interview report match our hiring scorecard."]),
    ]

    /// Once, on the first launch with this page: the switch already on means
    /// the person connected through the first version, so they see
    /// "Connected" and skip the first-connection banner.
    static func migrateV1(_ d: UserDefaults = .standard) {
        guard d.object(forKey: v1CheckedKey) == nil else { return }
        d.set(true, forKey: v1CheckedKey)
        if d.bool(forKey: MCPServer.enabledKey) {
            d.set(true, forKey: v1ConnectedKey)
            d.set(true, forKey: bannerShownKey)
        }
    }

    static func isConnected(_ d: UserDefaults = .standard) -> Bool {
        d.object(forKey: MCPAccess.firstReadKey) != nil || d.bool(forKey: v1ConnectedKey)
    }

    /// "claude-ai", "cursor-vscode", "codex-mcp-client" → a name people know.
    static func appName(_ client: String?) -> String {
        let c = (client ?? "").lowercased()
        if c.contains("claude") { return "Claude" }
        if c.contains("cursor") { return "Cursor" }
        if c.contains("codex") { return "Codex" }
        return "An AI app"
    }

    /// The activity line. Counts and times only, never content.
    static func statusLine(enabled: Bool, connected: Bool, app: String?, readsToday: Int,
                           lastRead: Date?, now: Date = .now) -> String {
        guard enabled else { return "Off. AI apps can't read your meetings." }
        guard connected else { return "On. Connect an app below, then ask it something." }
        let who = appName(app)
        if readsToday > 0, let lastRead {
            let times = readsToday == 1 ? "once" : "\(readsToday) times"
            return "Connected. \(who) checked your meetings \(times) today, last at \(lastRead.formatted(date: .omitted, time: .shortened))."
        }
        if let lastRead {
            return "Connected. \(who) last checked your meetings \(lastRead.formatted(.relative(presentation: .named, unitsStyle: .wide)))."
        }
        return "Connected."
    }

    static func showBanner(_ d: UserDefaults = .standard) -> Bool {
        d.bool(forKey: MCPServer.enabledKey) && d.object(forKey: MCPAccess.firstReadKey) != nil && !d.bool(forKey: bannerShownKey)
    }

    /// After a report finishes (within a day), at most once a week, never after "Don't show again".
    static func showTip(reportEnded: Date, lastShown: Date?, off: Bool, now: Date = .now) -> Bool {
        let week: TimeInterval = 7 * 86_400
        return !off && now.timeIntervalSince(reportEnded) < 86_400
            && lastShown.map { now.timeIntervalSince($0) >= week } ?? true
    }

    enum Question: String, CaseIterable, Identifiable {
        case followUp = "Follow-up email", secondOpinion = "Second opinion", agreed = "What did we agree?"
        var id: String { rawValue }
    }

    /// A question that names the meeting, so Claude finds the right one.
    static func question(_ q: Question, title: String, date: Date) -> String {
        let meeting = "my meeting \"\(title)\" on \(date.formatted(date: .abbreviated, time: .shortened))"
        switch q {
        case .followUp: return "Use Parrot to draft a follow-up email for \(meeting)."
        case .secondOpinion: return "Use Parrot to read \(meeting) and give me a second opinion: what went well, what I missed, what to do next."
        case .agreed: return "Use Parrot: what did we agree in \(meeting), and who owes what?"
        }
    }

    enum CommandApp: String { case claudeCode = "Claude Code", codex = "Codex" }

    /// What to do after Copy Command. People pasted it into the AI app's chat
    /// (where it fails, or asks for permission) instead of Terminal.
    static func pasteSteps(_ app: CommandApp) -> [String] {
        let last = app == .codex ? "Quit and reopen the ChatGPT app. Parrot is now in Codex."
                                 : "Start a new Claude Code session. Parrot is now in every project."
        return ["Click Open Terminal (it's the Terminal app, not a chat window).",
                "Paste with ⌘V and press Return.", last]
    }

    /// Whether this meeting may be offered to an AI app at all.
    static func mayShare(_ m: Meeting) -> Bool {
        m.status == .done && CloudGate.mayLeaveMac(m) && m.profile?.onDeviceOnly != true
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Makes the install file and hands it to Claude Desktop, which shows its
    /// Install screen. The Claude & AI Apps page and onboarding both use it.
    static func connectClaude(at app: URL) throws {
        let file = try MCPBundle.build(appPath: Bundle.main.bundlePath, version: AppUpdater.currentVersion,
                                       icon: MCPBundle.bundledIcon)
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Brings Claude Desktop forward, if it's installed.
    static func openClaude() {
        guard let url = appURL(MCPBundle.claudeBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - The page

struct AIAppsPageView: View {
    @AppStorage(MCPServer.enabledKey) private var enabled = false
    @AppStorage(MCPAccess.transcriptsKey) private var transcripts = true
    @AppStorage(MCPAccess.reportsKey) private var reports = true
    @AppStorage(MCPAccess.notesKey) private var notes = true
    @AppStorage(MCPAccess.cardsKey) private var cards = false
    @AppStorage(MCPServer.suggestionsKey) private var suggestions = true
    @Query(sort: \CallProfile.sortOrder) private var profiles: [CallProfile]
    @State private var excluded: Set<UUID> = []
    /// Bumped to re-read the counters the --mcp process writes (another process: no KVO).
    @State private var now = Date()
    @State private var copied: String?
    @State private var connectProblem: String?
    /// Which app's command was just copied, for the steps under it.
    @State private var stepsFor: AIApps.CommandApp?

    private var executable: String { Bundle.main.executablePath ?? "/Applications/Parrot.app/Contents/MacOS/Parrot" }

    var body: some View {
        SettingsPage {
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude & AI Apps")
                    .font(Theme.Typography.title())
                    .foregroundStyle(Theme.Colors.ink)
                Text("Use your meetings in Claude, Codex or Cursor: search them, catch up, draft follow-ups, improve your profiles. Nothing changes without your OK, and your own plan does the thinking.")
                    .font(Theme.Typography.lede)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Ask Parrot runs on your Mac and stays private. Claude is a bigger brain for bigger jobs (writing, many calls at once), using your Claude plan.")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "Connection") {
                SettingsToggleRow(title: "Allow AI apps to read my meetings", first: true, isOn: $enabled)
                SettingsToggleRow(title: "Let AI apps suggest profiles",
                                  detail: "Claude, Cursor or Codex can send a suggested profile. You review every change in Parrot first.",
                                  isOn: $suggestions)
                    .disabled(!enabled)
                SettingsRow {
                    Label(statusLine, systemImage: enabled && AIApps.isConnected() ? "checkmark.circle.fill" : "circle")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(enabled && AIApps.isConnected() ? Theme.Colors.good : Theme.Colors.ink2)
                }
            }

            connectCard

            SettingsCard(title: "What AI Apps Can See",
                         blurb: "When Claude reads a meeting, that text goes to Anthropic under your Claude account. Other apps work the same way with their own company.") {
                SettingsToggleRow(title: "Transcripts", detail: "Every line, with speaker names.", first: true, isOn: $transcripts)
                SettingsToggleRow(title: "Reports", detail: "Summary, next steps and coaching.", isOn: $reports)
                SettingsToggleRow(title: "My notes", isOn: $notes)
                SettingsToggleRow(title: "Assistant cards", detail: "What the Assistant showed during the call.", isOn: $cards)
                SettingsLabeledRow(title: "Hide these call types", detail: excludedSummary) {
                    Menu("Choose") {
                        ForEach(profiles) { p in
                            Toggle(p.name, isOn: excludedBinding(p.id))
                        }
                    }
                    .fixedSize()
                }
                SettingsRow {
                    Text("Never shown: meetings marked on-device only, audio, API keys and settings. AI apps can't change, delete or record meetings. Profile suggestions wait for your review.")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(title: "What You Can Ask",
                         blurb: "In Claude, the + button also has ready-made actions: weekly digest, follow-up email, prep for a call, PRD from calls.") {
                ForEach(Array(AIApps.jobs.enumerated()), id: \.element.id) { i, job in
                    SettingsBlockRow(title: job.title, first: i == 0) {
                        ForEach(job.examples, id: \.self) { example in
                            HStack(spacing: Theme.Metrics.controlGap) {
                                Text("“\(example)”")
                                    .font(Theme.Typography.secondary)
                                    .foregroundStyle(Theme.Colors.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Button(copied == example ? "Copied" : "Copy") {
                                    AIApps.copy(example)
                                    copied = example
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            AIApps.migrateV1()
            excluded = MCPAccess(defaults: .standard).excludedProfiles
            now = .now
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in now = .now }
    }

    private var statusLine: String {
        _ = now
        let d = UserDefaults.standard
        return AIApps.statusLine(enabled: enabled, connected: AIApps.isConnected(d),
                                 app: d.string(forKey: MCPAccess.lastAppKey),
                                 readsToday: MCPAccess.readsToday(in: d, now: now),
                                 lastRead: d.object(forKey: MCPAccess.lastReadKey) as? Date, now: now)
    }

    private var connectCard: some View {
        let claude = AIApps.appURL(MCPBundle.claudeBundleID)
        let cursor = AIApps.appURL(MCPBundle.cursorBundleID)
        return SettingsCard(title: "Connect an App",
                            blurb: enabled ? connectProblem : "Turn on the switch above first.") {
            SettingsLabeledRow(title: "Claude Desktop",
                               detail: claude == nil ? "Not installed." : "Opens Claude's install screen. Click Install.",
                               first: true) {
                if let claude {
                    Button("Connect") { connectClaude(at: claude) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Claude") { NSWorkspace.shared.open(MCPBundle.claudeDownloadURL) }
                }
            }
            SettingsLabeledRow(title: "Claude Code", detail: "Copy a command, then paste it in Terminal.") {
                copyButton(MCPBundle.claudeCodeCommand(executable: executable), label: "Copy Command", steps: .claudeCode)
            }
            if stepsFor == .claudeCode { pasteSteps(.claudeCode) }
            SettingsLabeledRow(title: "Codex", detail: "In the ChatGPT app, for ChatGPT plans. Copy a command, then paste it in Terminal.") {
                copyButton(MCPBundle.codexCommand(executable: executable, codexCLI: MCPBundle.installedCodexCLI),
                           label: "Copy Command", steps: .codex)
            }
            if stepsFor == .codex { pasteSteps(.codex) }
            SettingsLabeledRow(title: "Cursor", detail: cursor == nil ? "Not installed." : "Opens Cursor's install prompt.") {
                Button("Connect") {
                    if let link = MCPBundle.cursorLink(executable: executable) { NSWorkspace.shared.open(link) }
                }
                .disabled(cursor == nil)
            }
            SettingsLabeledRow(title: "Another app", detail: "The setup most MCP apps accept.") {
                copyButton(MCPServer.claudeDesktopConfig(executable: executable), label: "Copy Setup")
            }
        }
        .disabled(!enabled)
    }

    private func copyButton(_ text: String, label: String, steps: AIApps.CommandApp? = nil) -> some View {
        Button(copied == text ? "Copied" : label) {
            AIApps.copy(text)
            copied = text
            stepsFor = steps
        }
    }

    /// Numbered next steps and a way into Terminal, under the row just copied.
    private func pasteSteps(_ app: AIApps.CommandApp) -> some View {
        SettingsRow {
            HStack(alignment: .top, spacing: Theme.Metrics.controlGap) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Copied. Now:")
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Colors.ink)
                    ForEach(Array(AIApps.pasteSteps(app).enumerated()), id: \.offset) { i, step in
                        Text("\(i + 1). \(step)")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Colors.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button("Open Terminal") {
                    if let terminal = AIApps.appURL("com.apple.Terminal") {
                        NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(Theme.Metrics.popoverPad)
            .background(Theme.Colors.spotlight, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        }
    }

    private func connectClaude(at app: URL) {
        do {
            try AIApps.connectClaude(at: app)
            connectProblem = nil
        } catch {
            connectProblem = "Couldn't make the install file. Use Another app → Copy Setup instead."
        }
    }

    private var excludedSummary: String {
        let names = profiles.filter { excluded.contains($0.id) }.map(\.name)
        return names.isEmpty ? "None. Every call type is shared." : names.joined(separator: ", ")
    }

    private func excludedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { excluded.contains(id) },
            set: { hide in
                if hide { excluded.insert(id) } else { excluded.remove(id) }
                UserDefaults.standard.set(excluded.map(\.uuidString).sorted(), forKey: MCPAccess.excludedKey)
            })
    }
}

// MARK: - Around the app

/// Once, the first time an AI app reads Parrot: what to try first.
struct AIAppsConnectedBanner: View {
    @State private var visible = false
    @State private var copied = false

    var body: some View {
        Group {
            if visible {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Colors.good)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(AIApps.appName(UserDefaults.standard.string(forKey: MCPAccess.lastAppKey))) is connected")
                            .font(Theme.Typography.cardTitle)
                            .foregroundStyle(Theme.Colors.ink)
                        Text("Try this first: “\(AIApps.firstQuestion)”")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.ink2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button(copied ? "Copied" : "Copy") {
                        AIApps.copy(AIApps.firstQuestion)
                        copied = true
                    }
                    .controlSize(.small)
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, Theme.Metrics.popoverPad)
                .padding(.vertical, Theme.Metrics.bannerInsetV)
                .frame(maxWidth: 460, alignment: .leading)
                .background(Theme.Colors.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.Colors.line))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear(perform: check)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in check() }
    }

    private func check() {
        AIApps.migrateV1()
        guard !visible, AIApps.showBanner() else { return }
        // Shown once, however it ends.
        UserDefaults.standard.set(true, forKey: AIApps.bannerShownKey)
        withAnimation { visible = true }
    }

    private func dismiss() {
        withAnimation { visible = false }
    }
}

/// The meeting page's "Ask Claude" menu: copies a question naming this
/// meeting and brings Claude forward. Hidden when the switch is off or the
/// meeting may not be shared.
struct AskClaudeMenu: View {
    let meeting: Meeting
    @AppStorage(MCPServer.enabledKey) private var enabled = false

    var body: some View {
        if enabled, AIApps.mayShare(meeting) {
            Menu {
                ForEach(AIApps.Question.allCases) { q in
                    Button(q.rawValue) {
                        AIApps.copy(AIApps.question(q, title: meeting.title, date: meeting.date))
                        AIApps.openClaude()
                    }
                }
                Divider()
                Text("Copies the question. Paste it in Claude.")
            } label: {
                Label("Ask Claude", systemImage: "bubble.left.and.text.bubble.right")
            }
            .help("Copy a question about this meeting for Claude")
        }
    }
}

/// After a finished report, now and then: what Claude can do with it.
struct AIAppsReportTip: View {
    let meeting: Meeting
    @State private var visible = false

    var body: some View {
        Group {
            if visible {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(Theme.Colors.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Claude can turn this call into a follow-up email, a second opinion or a list of who owes what.")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Colors.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: Theme.Metrics.controlGap) {
                            Button("Show Me How") {
                                NotificationCenter.default.post(name: .parrotOpenAIApps, object: nil)
                            }
                            .controlSize(.small)
                            Button("Don't Show Again") {
                                UserDefaults.standard.set(true, forKey: AIApps.tipsOffKey)
                                visible = false
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { visible = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                }
                .padding(Theme.Metrics.popoverPad)
                .background(Theme.Colors.spotlight, in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius))
            }
        }
        .onAppear {
            // Decided once per appearance, so recording the showing doesn't hide it again.
            let d = UserDefaults.standard
            guard AIApps.mayShare(meeting), meeting.summary != nil || meeting.coaching != nil,
                  AIApps.showTip(reportEnded: meeting.date.addingTimeInterval(meeting.duration),
                                 lastShown: d.object(forKey: AIApps.tipLastShownKey) as? Date,
                                 off: d.bool(forKey: AIApps.tipsOffKey))
            else { return }
            d.set(Date(), forKey: AIApps.tipLastShownKey)
            visible = true
        }
    }
}
