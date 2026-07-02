import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(\.modelContext) private var modelContext
    @State private var selectedMeeting: Meeting?
    @State private var showDashboard = true
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var hasLoadedModel = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedMeeting: $selectedMeeting,
                showDashboard: $showDashboard,
                showSettings: $showSettings,
                searchText: $searchText
            )
            .navigationSplitViewColumnWidth(min: 215, ideal: 236, max: 320)
        } detail: {
            if recordingManager.isRecording {
                LiveRecordingView()
            } else if showSettings {
                settingsPane
            } else if showDashboard {
                DashboardView(
                    selectedMeeting: $selectedMeeting,
                    showDashboard: $showDashboard
                )
            } else if let meeting = selectedMeeting {
                // .id forces a fresh view identity per meeting: @State (title/name
                // drafts, audio players, tab) must not leak from one meeting to the
                // next, and onAppear/onDisappear must re-fire to stop playback.
                MeetingDetailView(meeting: meeting, onDelete: {
                    // Clear the selection first so the detail view is gone
                    // before its model object is deleted.
                    selectedMeeting = nil
                    showDashboard = true
                    recordingManager.delete(meeting)
                })
                .id(meeting.id)
            } else {
                EmptyStateView()
            }
        }
        .task {
            guard !hasLoadedModel else { return }
            hasLoadedModel = true
            await recordingManager.prepare(modelContext: modelContext)
        }
    }

    /// Settings in the main pane — the old sheet was a cramped 520pt popup.
    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(Theme.Typography.title(24))
                .foregroundStyle(Theme.Colors.ink)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 10)

            // Full bleed — no width cap, no centering. A wider window means a
            // wider editor, period.
            SettingsView(isEmbedded: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.canvas)
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Select a meeting or start recording")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
