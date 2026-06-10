import SwiftUI
import SwiftData

@main
struct ParrotApp: App {
    @State private var recordingManager = RecordingManager()
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self])
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
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding)
                        .environment(recordingManager)
                        .interactiveDismissDisabled()
                }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 900, height: 600)

        MenuBarExtra {
            MenuBarView()
                .environment(recordingManager)
                .modelContainer(sharedModelContainer)
        } label: {
            Image(systemName: recordingManager.isRecording ? "waveform.circle.fill" : "waveform")
        }

        Settings {
            SettingsView()
                .environment(recordingManager)
        }
    }
}
