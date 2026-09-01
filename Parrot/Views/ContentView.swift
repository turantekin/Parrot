import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSession.self) private var appSession
    @Environment(\.modelContext) private var modelContext
    @State private var selectedMeeting: Meeting?
    @State private var showDashboard = true
    @State private var showSettings = false
    @State private var showDictations = false
    @State private var showTransforms = false
    @State private var showTranslate = false
    @State private var selectedDictation: DictationNote?
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
                showDictations: $showDictations,
                showTransforms: $showTransforms,
                showTranslate: $showTranslate,
                searchText: $searchText
            )
            .navigationSplitViewColumnWidth(min: 215, ideal: 236, max: 320)
        } detail: {
            switch MainDetailPane.resolve(
                isRecording: recordingManager.isRecording,
                showTranslate: showTranslate,
                showDictations: showDictations,
                showTransforms: showTransforms,
                showSettings: showSettings,
                showDashboard: showDashboard,
                hasMeeting: selectedMeeting != nil
            ) {
            case .live:
                LiveRecordingView()
            case .translate:
                TranslateSetupView()
            case .dictations:
                DictationListView(selected: $selectedDictation)
            case .transforms:
                TransformsView()
            case .settings:
                settingsPane
            case .dashboard:
                DashboardView(
                    selectedMeeting: $selectedMeeting,
                    showDashboard: $showDashboard
                )
            case .meeting:
                if let meeting = selectedMeeting {
                    // .id forces a fresh view identity per meeting: @State (title/name
                    // drafts, audio players, tab) must not leak from one meeting to the
                    // next, and onAppear/onDisappear must re-fire to stop playback.
                    MeetingDetailView(meeting: meeting, onDelete: {
                        selectedMeeting = nil
                        showDashboard = true
                        recordingManager.delete(meeting)
                    })
                    .id(meeting.id)
                } else {
                    EmptyStateView()
                }
            case .empty:
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
                if recordingManager.isRecording, !showingLiveCall {
                    RecordingAwayBanner(
                        elapsed: recordingManager.formattedElapsedTime,
                        stopping: recordingManager.isStopping,
                        onShow: { openLiveCall() },
                        onStop: {
                            Task { @MainActor in
                                await recordingManager.stopRecording()
                            }
                        }
                    )
                }
                ProcessingHUD(text: recordingManager.dictation.phase.hud)
                ProcessingHUD(text: recordingManager.transforms.phase.hud)
            }
            .padding(.top, 12)
        }
        .overlay(alignment: .bottomTrailing) {
            if !showingLiveCall {
                BugReportButton { presentBugReport() }
                    .padding(16)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showBugReport) {
            BugReportSheet(screenshot: reportScreenshot)
        }
        .onReceive(NotificationCenter.default.publisher(for: .parrotReportBug)) { _ in
            presentBugReport()
        }
        .animation(.easeInOut(duration: 0.2), value: recordingManager.importProgress)
        // Mirror the selection for the File → Export menu items.
        .onChange(of: selectedMeeting) { _, meeting in
            appSession.selectedMeeting = meeting
        }
        .onChange(of: recordingManager.isRecording) { _, recording in
            if recording {
                if MainDetailPane.shouldOpenLiveOnStart(
                    showTranslate: showTranslate,
                    showDictations: showDictations,
                    showTransforms: showTransforms,
                    showSettings: showSettings,
                    showDashboard: showDashboard,
                    hasMeeting: selectedMeeting != nil
                ) {
                    openLiveCall()
                }
            } else if MainDetailPane.shouldRevealMeetingOnStop(
                showTranslate: showTranslate,
                showDictations: showDictations,
                showTransforms: showTransforms,
                showSettings: showSettings,
                showDashboard: showDashboard,
                hasMeeting: selectedMeeting != nil
            ) {
                if let meeting = recordingManager.currentMeeting {
                    selectedMeeting = meeting
                    showDashboard = false
                } else {
                    showDashboard = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .parrotShowTranscriptionSettings)) { _ in
            SettingsSection.pending = .create
            showSettings = true
            showDashboard = false
            selectedMeeting = nil
            showDictations = false
            showTransforms = false
            showTranslate = false
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

    private var showingLiveCall: Bool {
        MainDetailPane.resolve(
            isRecording: recordingManager.isRecording,
            showTranslate: showTranslate,
            showDictations: showDictations,
            showTransforms: showTransforms,
            showSettings: showSettings,
            showDashboard: showDashboard,
            hasMeeting: selectedMeeting != nil
        ) == .live
    }

    private func openLiveCall() {
        showSettings = false
        showDictations = false
        showTransforms = false
        showTranslate = false
        selectedMeeting = nil
        showDashboard = false
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
        showDictations = false
        showTransforms = false
        showTranslate = false
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

/// Which detail pane wins. Sidebar destinations beat the live call so Settings
/// and dictation stay reachable while a recording runs.
enum MainDetailPane: Equatable {
    case live, translate, dictations, transforms, settings, dashboard, meeting, empty

    static func resolve(
        isRecording: Bool,
        showTranslate: Bool,
        showDictations: Bool,
        showTransforms: Bool,
        showSettings: Bool,
        showDashboard: Bool,
        hasMeeting: Bool
    ) -> MainDetailPane {
        if showTranslate { return .translate }
        if showDictations { return .dictations }
        if showTransforms { return .transforms }
        if showSettings { return .settings }
        if hasMeeting { return .meeting }
        if showDashboard { return .dashboard }
        if isRecording { return .live }
        return .empty
    }

    /// Start Recording from the menu bar should not yank Settings / a meeting.
    static func shouldOpenLiveOnStart(
        showTranslate: Bool,
        showDictations: Bool,
        showTransforms: Bool,
        showSettings: Bool,
        showDashboard: Bool,
        hasMeeting: Bool
    ) -> Bool {
        switch resolve(
            isRecording: false,
            showTranslate: showTranslate,
            showDictations: showDictations,
            showTransforms: showTransforms,
            showSettings: showSettings,
            showDashboard: showDashboard,
            hasMeeting: hasMeeting
        ) {
        case .dashboard, .empty: true
        default: false
        }
    }

    /// Only the live call pane jumps to the finished meeting on Stop.
    static func shouldRevealMeetingOnStop(
        showTranslate: Bool,
        showDictations: Bool,
        showTransforms: Bool,
        showSettings: Bool,
        showDashboard: Bool,
        hasMeeting: Bool
    ) -> Bool {
        resolve(
            isRecording: true,
            showTranslate: showTranslate,
            showDictations: showDictations,
            showTransforms: showTransforms,
            showSettings: showSettings,
            showDashboard: showDashboard,
            hasMeeting: hasMeeting
        ) == .live
    }
}

private struct RecordingAwayBanner: View {
    let elapsed: String
    var stopping: Bool
    var onShow: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.Colors.stop)
                .frame(width: 8, height: 8)
            Text(elapsed)
                .font(Theme.Typography.mono(11))
                .foregroundStyle(Theme.Colors.ink)
            Button("Show call", action: onShow)
                .buttonStyle(.link)
                .font(Theme.Typography.secondary)
            Button(stopping ? "Finalizing…" : "Stop", action: onStop)
                .buttonStyle(.link)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.stop)
                .disabled(stopping)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.Colors.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.Colors.line))
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
