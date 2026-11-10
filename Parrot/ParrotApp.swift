import SwiftUI
import SwiftData

@main
struct ParrotMain {
    /// Entry point. `--snapshot <path>` renders the report offscreen to a PNG for
    /// design verification (see SnapshotTool.swift); otherwise the normal app runs.
    static func main() {
        let args = CommandLine.arguments
        // Launched by an AI app (Claude Desktop…) as its MCP server: stdio,
        // read-only, refuses unless enabled in Settings → Connections.
        if args.contains("--mcp") {
            Task { @MainActor in await MCPServer.run() }
            dispatchMain()
        }
        // Release packaging: the Claude Desktop install file (scripts/release.sh).
        if let i = args.firstIndex(of: "--mcpb"), i + 2 < args.count {
            exit(MCPBundle.writeRelease(to: args[i + 1], version: args[i + 2], iconPath: i + 3 < args.count ? args[i + 3] : nil))
        }
        if let i = args.firstIndex(of: "--whats-new-html"), i + 1 < args.count {
            exit(WhatsNew.printHTML(for: args[i + 1]))
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { ReportSnapshot.write(to: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--copilot-snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { CopilotSnapshot.write(to: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--sidebar-snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { SidebarSnapshot.write(to: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--help-shots"), i + 1 < args.count {
            MainActor.assumeIsolated { HelpShots.run(outputDir: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--liveloop-test"), i + 1 < args.count {
            let model = (i + 2 < args.count) ? args[i + 2] : ""
            LiveLoopTest.run(audioPath: args[i + 1], model: model)
            return
        }
        if let i = args.firstIndex(of: "--transcribe-test"), i + 1 < args.count {
            let modelFolder = (i + 2 < args.count) ? args[i + 2] : ""
            TranscribeTest.run(audioPath: args[i + 1], modelFolder: modelFolder)
            return
        }
        if let i = args.firstIndex(of: "--language-test"), i + 1 < args.count {
            let modelFolder = (i + 2 < args.count) ? args[i + 2] : ""
            let seconds = (i + 3 < args.count) ? Int(args[i + 3]) : nil
            TranscribeTest.detectLanguage(audioPath: args[i + 1], modelFolder: modelFolder, seconds: seconds)
            return
        }
        if let i = args.firstIndex(of: "--diarize-test"), i + 1 < args.count {
            DiarizeTest.run(audioPath: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--echo-replay"), i + 2 < args.count {
            EchoReplay.run(micPath: args[i + 1], systemPath: args[i + 2],
                           linesPath: i + 3 < args.count ? args[i + 3] : nil)
            return
        }
        if let i = args.firstIndex(of: "--aec-replay"), i + 2 < args.count {
            AECReplay.run(micPath: args[i + 1], refPath: args[i + 2])
            return
        }
        if let i = args.firstIndex(of: "--capture-test") {
            let seconds = (i + 1 < args.count) ? (Double(args[i + 1]) ?? 10) : 10
            CaptureTest.run(seconds: seconds)
            return
        }
        if let i = args.firstIndex(of: "--kb-add"), i + 1 < args.count {
            MainActor.assumeIsolated { KBAddTool.run(path: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--doc-answer-eval"), i + 1 < args.count {
            let shape = (i + 2 < args.count) ? args[i + 2] : "single"
            DocAnswerEval.run(labelsPath: args[i + 1], shape: shape)
            return
        }
        if let i = args.firstIndex(of: "--copilot-replay"), i + 1 < args.count {
            let rest = Array(args[(i + 2)...])
            MainActor.assumeIsolated { CopilotReplay.run(transcriptPath: args[i + 1], args: rest) }
            return
        }
        if let i = args.firstIndex(of: "--nudge-replay") {
            MainActor.assumeIsolated { NudgeReplay.run(args: Array(args[(i + 1)...])) }
            return
        }
        if let i = args.firstIndex(of: "--pill-test") {
            let out = (i + 1 < args.count) ? args[i + 1] : nil
            MainActor.assumeIsolated { PillTest.run(out: out) }
            return
        }
        if let i = args.firstIndex(of: "--tone-snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { ToneSnapshot.write(to: args[i + 1]) }
            return
        }
        if let i = args.firstIndex(of: "--report-pdf") {
            MainActor.assumeIsolated { ReportPDFHarness.run(args: Array(args[(i + 1)...])) }
            return
        }
        if let i = args.firstIndex(of: "--about-test") {
            MainActor.assumeIsolated { AboutTest.run(args: Array(args[(i + 1)...])) }
            return
        }
        if let i = args.firstIndex(of: "--store-upgrade-test"), i + 1 < args.count {
            MainActor.assumeIsolated { StoreUpgradeTest.run(path: args[i + 1]) }
            return
        }
        if args.contains("--profile-test") {
            MainActor.assumeIsolated { ProfileTest.run() }
            return
        }
        if let i = args.firstIndex(of: "--analyze-test") {
            let provider = (i + 1 < args.count) ? args[i + 1] : nil
            let model = (i + 2 < args.count) ? args[i + 2] : nil
            AnalyzeTest.run(provider: provider, model: model)
            return
        }
        if let i = args.firstIndex(of: "--ask-real"), i + 2 < args.count {
            let model = (i + 3 < args.count) ? args[i + 3] : nil
            MainActor.assumeIsolated { AskRealTest.run(provider: args[i + 1], path: args[i + 2], model: model) }
            return
        }
        if let i = args.firstIndex(of: "--ask-chat-test") {
            let provider = (i + 1 < args.count) ? args[i + 1] : nil
            let model = (i + 2 < args.count) ? args[i + 2] : nil
            MainActor.assumeIsolated { AskChatTest.run(provider: provider, model: model) }
            return
        }
        ParrotApp.main()
    }
}

/// Cmd-Q mid-recording used to kill capture mid-flight: the .caf headers never
/// finalized and the meeting stayed `.recording`, feeding the #18 relaunch
/// crash-loop. Quit now runs the same stop path as the Stop button, then
/// terminates. The post-stop report chain is deliberately not awaited — the
/// meeting exits as `.processing` and launch recovery finishes it by design.
@MainActor
final class ParrotAppDelegate: NSObject, NSApplicationDelegate {
    weak var recordingManager: RecordingManager?
    /// Set once the window is up; links that came before wait in `pendingLink`.
    weak var appSession: AppSession? { didSet { deliverLink(); deliverProfiles() } }
    /// Reopens the main window when a link arrives after it was closed.
    var openMainWindow: OpenWindowAction?
    private var pendingLink: AppSession.Jump?
    /// .parrotprofile files opened before the window was up.
    private var pendingProfiles: [PendingProfile] = []

    /// openparrot:// links (ParrotLink), e.g. a time Claude cited: the same
    /// jump as an Ask Parrot chip. Here, not SwiftUI's onOpenURL, which drops
    /// the link when it's what launched Parrot.
    func application(_ application: NSApplication, open urls: [URL]) {
        // A double-clicked .parrotprofile: read now (the sandbox lets us
        // read it during this call), review later.
        pendingProfiles += urls.filter { $0.pathExtension.lowercased() == "parrotprofile" }.compactMap { PendingProfile.read($0) }
        deliverProfiles()
        guard let link = urls.lazy.compactMap(ParrotLink.parse).first else { return }
        pendingLink = AppSession.Jump(meetingID: link.id, time: link.time)
        deliverLink()
    }

    private func deliverLink() {
        guard let session = appSession, let jump = pendingLink else { return }
        pendingLink = nil
        // Parrot still runs with its window closed; a link brings it back
        // (the new window picks the jump up as it appears).
        Self.showInDock()
        if ParrotApp.mainWindow == nil {
            openMainWindow?(id: ParrotApp.mainWindowID)
        }
        NSApp.activate()
        // Next turn of the run loop, so the window's jump handler is listening.
        DispatchQueue.main.async { session.pendingJump = jump }
    }

    private func deliverProfiles() {
        guard let session = appSession, !pendingProfiles.isEmpty else { return }
        Self.showInDock()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            openMainWindow?(id: ParrotApp.mainWindowID)
        }
        NSApp.activate()
        session.profileReviews += pendingProfiles
        pendingProfiles = []
    }

    /// Settings → General: leave the Dock while the window is closed (#118).
    static let hideDockKey = "hideDockWhenClosed"

    /// macOS started Parrot as a login item: start in the menu bar with no
    /// window (#153), like the Settings row promises. Opened by hand, the
    /// window shows as always. `-debugLoginLaunch YES` fakes it for testing.
    private(set) static var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        Self.launchedAtLogin = UserDefaults.standard.bool(forKey: "debugLoginLaunch")
            || (event?.eventID == kAEOpenApplication
                && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem)
    }

    /// Once, for the window that opens at launch: true when it should close
    /// straight away. Never before the Welcome Tour is done.
    func takeLoginLaunch() -> Bool {
        defer { Self.launchedAtLogin = false }
        return Self.launchedAtLogin && UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // After the close has finished: until then the window still counts.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Self.hideFromDockIfClosed() }
        }
    }

    /// With the setting on and the window closed, Parrot lives in the menu
    /// bar only: no Dock icon, no ⌘-Tab, no menus at the top of the screen.
    static func hideFromDockIfClosed() {
        guard UserDefaults.standard.bool(forKey: hideDockKey), ParrotApp.mainWindow == nil,
              NSApp.activationPolicy() != .accessory else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Every way to open the window calls this first. Before, not after: a
    /// window that opens behind another app tells us nothing, and switched
    /// while Parrot is already in front, the menus at the top can stay away.
    static func showInDock() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// A Dock click (or opening Parrot again) with the window closed brings
    /// it back. SwiftUI's own reopen never did: the window group takes no
    /// outside events, so links land in the window that's there.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard ParrotApp.mainWindow == nil else { return true }
        Self.showInDock()
        openMainWindow?(id: ParrotApp.mainWindowID)
        NSApp.activate()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager = recordingManager, manager.isRecording || manager.isStopping else {
            return .terminateNow
        }
        Task { @MainActor in
            await manager.stopRecording()      // no-op if a stop is already draining…
            while manager.isStopping {         // …so wait that one out instead
                try? await Task.sleep(for: .milliseconds(100))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct ParrotApp: App {
    static let mainWindowID = "main"
    /// The main window, shown or minimised; nil once closed (Settings
    /// doesn't count). SwiftUI names a WindowGroup's windows "<id>-AppWindow-<n>".
    @MainActor static var mainWindow: NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue.hasPrefix("\(mainWindowID)-") == true && ($0.isVisible || $0.isMiniaturized)
        }
    }
    @NSApplicationDelegateAdaptor(ParrotAppDelegate.self) private var appDelegate
    @State private var recordingManager = RecordingManager()
    @State private var appSession = AppSession()
    // Live, not a launch-time snapshot: Settings and Help → Show Welcome Tour
    // re-open the tour by clearing this key, and the sheet presents without a
    // relaunch. Completing the tour sets it back through the same binding.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    private var showOnboarding: Binding<Bool> {
        Binding(get: { !hasCompletedOnboarding }, set: { hasCompletedOnboarding = !$0 })
    }
    /// Same key/enum as SettingsView's Appearance picker.
    @AppStorage("appearance") private var appearance = Appearance.system

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView()
                .parrotEnvironment(recordingManager, appSession)
                .sheet(isPresented: showOnboarding) {
                    OnboardingView(isPresented: showOnboarding)
                        .parrotEnvironment(recordingManager, appSession)
                        .interactiveDismissDisabled()
                }
                .onAppear {
                    applyAppearance()
                    appDelegate.recordingManager = recordingManager
                    appDelegate.appSession = appSession
                    // Login launch: close after the delegate has what it needs
                    // to reopen (Dock click, links), so Parrot waits in the
                    // menu bar. Closing also drops the Dock icon if that's on.
                    if appDelegate.takeLoginLaunch() {
                        DispatchQueue.main.async { ParrotApp.mainWindow?.close() }
                    }
                }
                .background {
                    WindowOpener { appDelegate.openMainWindow = $0 }
                }
                .onChange(of: appearance) { applyAppearance() }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 900, height: 600)
        // A link that launches Parrot must not open a second window next to
        // the usual one: the delegate takes links into the window that's there.
        .handlesExternalEvents(matching: [])
        .commands {
            ParrotCommands(
                session: appSession,
                recordingManager: recordingManager,
                modelContext: sharedModelContainer.mainContext
            )
        }

        // A real menu, not a floating panel: instant, keyboard-navigable, native.
        MenuBarExtra {
            MenuBarView()
                .parrotEnvironment(recordingManager, appSession)
                .modelContainer(sharedModelContainer)
        } label: {
            MenuBarLabel(recordingManager: recordingManager)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .parrotEnvironment(recordingManager, appSession)
        }
        .modelContainer(sharedModelContainer)
    }

    /// Applies the Settings → Appearance choice app-wide (titlebar included).
    private func applyAppearance() {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Hands SwiftUI's window opener to the app delegate, which can't read the
/// environment itself.
private struct WindowOpener: View {
    let register: (OpenWindowAction) -> Void
    @Environment(\.openWindow) private var openWindow
    var body: some View { Color.clear.onAppear { register(openWindow) } }
}

extension View {
    /// The objects Parrot's views read with @Environment, for every scene and
    /// sheet. One list: the Settings window had its own and missed AppSession,
    /// so its Profiles page stopped the app (#131).
    func parrotEnvironment(_ recordingManager: RecordingManager, _ appSession: AppSession) -> some View {
        environment(recordingManager)
            .environment(recordingManager.profileStore)
            .environment(appSession)
    }
}
