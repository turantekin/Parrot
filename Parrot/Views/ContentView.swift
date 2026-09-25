import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSession.self) private var appSession
    @Environment(\.modelContext) private var modelContext
    @State private var selectedMeeting: Meeting?
    @State private var showDashboard = true
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var hasLoadedModel = false
    /// File → Import Audio… (⌘O); the dashboard has its own importer button.
    @State private var showMenuImporter = false
    @State private var showBugReport = false
    /// Grabbed when the button is pressed, before the sheet covers the thing
    /// the user wants to show us.
    @State private var reportScreenshot: NSImage?

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
        // Drop an audio file anywhere in the window to import it — off while
        // recording, which owns the shared WhisperKit.
        .audioImportDrop(enabled: !recordingManager.isRecording) { url in
            startImport(url)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let progress = recordingManager.importProgress {
                    ImportingBanner(progress: progress)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let prompt = recordingManager.callWatcher.prompt {
                    CallPromptBanner(
                        prompt: prompt,
                        onAccept: { recordingManager.callWatcher.acceptPrompt() },
                        onDismiss: { recordingManager.callWatcher.dismissPrompt() },
                        onIgnoreApp: { recordingManager.callWatcher.ignorePromptApp() }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 12)
        }
        .animation(.easeInOut(duration: 0.2), value: recordingManager.callWatcher.prompt)
        // Always reachable, except mid-call: a live recording is the one time
        // the window is nobody else's business (and it keeps the button out of
        // call screenshots).
        .overlay(alignment: .bottomTrailing) {
            if !recordingManager.isRecording {
                BugReportButton { presentBugReport() }
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showBugReport) {
            BugReportSheet(screenshot: reportScreenshot)
        }
        .sheet(item: Binding(get: { appSession.askRequest }, set: { appSession.askRequest = $0 })) { request in
            AskView(request: request)
                .environment(recordingManager)
                .environment(appSession)
        }
        .onReceive(NotificationCenter.default.publisher(for: .parrotMeetingWillDelete)) { note in
            guard let id = note.object as? UUID else { return }
            if selectedMeeting?.id == id {
                selectedMeeting = nil
                showDashboard = true
            }
            if appSession.selectedMeeting?.id == id { appSession.selectedMeeting = nil }
            if appSession.pendingJump?.meetingID == id { appSession.pendingJump = nil }
        }
        // Ask Parrot's citations: open that meeting (the detail view seeks).
        .onChange(of: appSession.pendingJump) { _, jump in
            guard let jump else { return }
            let id = jump.meetingID
            let found = try? modelContext.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })).first
            guard let meeting = found else {
                appSession.pendingJump = nil
                return
            }
            selectedMeeting = meeting
            showDashboard = false
            showSettings = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .parrotReportBug)) { _ in
            presentBugReport()
        }
        .animation(.easeInOut(duration: 0.2), value: recordingManager.importProgress)
        // Mirror the selection for the File → Export menu items.
        .onChange(of: selectedMeeting) { _, meeting in
            appSession.selectedMeeting = meeting
        }
        .onReceive(NotificationCenter.default.publisher(for: .parrotImportAudio)) { _ in
            if !recordingManager.isRecording { showMenuImporter = true }
        }
        .fileImporter(
            isPresented: $showMenuImporter,
            allowedContentTypes: AudioImport.contentTypes
        ) { result in
            if case .success(let url) = result { startImport(url) }
        }
        .task {
            guard !hasLoadedModel else { return }
            hasLoadedModel = true
            await recordingManager.prepare(modelContext: modelContext)
        }
    }

    private func presentBugReport() {
        reportScreenshot = BugReport.captureWindow()
        showBugReport = true
    }

    private func startImport(_ url: URL) {
        guard let meeting = recordingManager.importAudioFile(from: url, modelContext: modelContext) else { return }
        selectedMeeting = meeting
        showDashboard = false
        showSettings = false
    }

    /// Settings in the main pane — the old sheet was a cramped 520pt popup.
    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(Theme.Typography.title())
                .foregroundStyle(Theme.Colors.ink)
                .padding(.horizontal, Theme.Metrics.pad)
                .padding(.top, Theme.Metrics.pad)
                .padding(.bottom, 8)

            // Full bleed — no width cap, no centering. A wider window means a
            // wider editor, period. Base font is the body scale; controls
            // without an explicit font inherit it.
            SettingsView(isEmbedded: true)
                .font(Theme.Typography.body)
                .padding(.horizontal, Theme.Metrics.pad)
                .padding(.bottom, Theme.Metrics.pad)
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
                .foregroundStyle(Theme.Colors.ink3)
            Text("Select a meeting or start recording")
                .font(.appTitle3)
                .foregroundStyle(Theme.Colors.ink2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
