import SwiftUI
import SwiftData

@main
struct ParrotMain {
    /// Entry point. `--snapshot <path>` renders the report offscreen to a PNG for
    /// design verification (see SnapshotTool.swift); otherwise the normal app runs.
    static func main() {
        let args = CommandLine.arguments
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
        if let i = args.firstIndex(of: "--asr-bench"), i + 1 < args.count {
            AsrBench.run(arguments: Array(args[(i + 1)...]))
            return
        }
        if args.contains("--meeting-bench") {
            let i = args.firstIndex(of: "--meeting-bench")!
            MeetingBench.run(arguments: Array(args[(i + 1)...]))
            return
        }
        if args.contains("--translate-test") {
            TranslateTest.run()
            return
        }
        if let i = args.firstIndex(of: "--transcribe-test"), i + 1 < args.count {
            let modelFolder = (i + 2 < args.count) ? args[i + 2] : ""
            TranscribeTest.run(audioPath: args[i + 1], modelFolder: modelFolder)
            return
        }
        if let i = args.firstIndex(of: "--diarize-test"), i + 1 < args.count {
            DiarizeTest.run(audioPath: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--capture-test") {
            let seconds = (i + 1 < args.count) ? (Double(args[i + 1]) ?? 10) : 10
            CaptureTest.run(seconds: seconds)
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
        WindowGroup {
            ContentView()
                .environment(recordingManager)
                .environment(recordingManager.profileStore)
                .environment(appSession)
                .sheet(isPresented: showOnboarding) {
                    OnboardingView(isPresented: showOnboarding)
                        .environment(recordingManager)
                        .interactiveDismissDisabled()
                }
                .onAppear {
                    applyAppearance()
                    appDelegate.recordingManager = recordingManager
                }
                .onChange(of: appearance) { applyAppearance() }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 900, height: 600)
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
                .environment(recordingManager)
                .environment(recordingManager.profileStore)
                .modelContainer(sharedModelContainer)
        } label: {
            Image(systemName: recordingManager.isRecording ? "waveform.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(recordingManager)
                .environment(recordingManager.profileStore)
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
