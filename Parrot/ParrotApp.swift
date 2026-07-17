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
        if let i = args.firstIndex(of: "--transcribe-test"), i + 1 < args.count {
            let modelFolder = (i + 2 < args.count) ? args[i + 2] : ""
            TranscribeTest.run(audioPath: args[i + 1], modelFolder: modelFolder)
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

struct ParrotApp: App {
    @State private var recordingManager = RecordingManager()
    @State private var appSession = AppSession()
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    /// Same key/enum as SettingsView's Appearance picker.
    @AppStorage("appearance") private var appearance = Appearance.system

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self])
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
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding)
                        .environment(recordingManager)
                        .interactiveDismissDisabled()
                }
                .onAppear(perform: applyAppearance)
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
