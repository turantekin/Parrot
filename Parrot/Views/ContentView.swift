import SwiftUI
import SwiftData

/// What the main window's detail area shows. One value instead of flags,
/// so two pages can never both be "on".
enum MainPage: Equatable { case dashboard, settings, ask, aiApps, meeting }

struct ContentView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(AppSession.self) private var appSession
    @Environment(ProfileStore.self) private var profileStore
    /// The welcome tour's sheet; the Profiles 2.0 screen waits for it.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// The profile file on the review screen now.
    @State private var reviewing: PendingProfile?
    /// Suggestions the user said "Later" to this session (they stay in the inbox).
    @State private var laterIDs: Set<UUID> = []
    @Query(sort: \CallProfile.sortOrder) private var profiles: [CallProfile]

    /// The AI suggestion the banner offers, if any.
    private var suggestion: PendingProfile? {
        appSession.profileReviews.first { item in
            if case .suggestion = item.origin { return !laterIDs.contains(item.id) } else { return false }
        }
    }
    @Environment(\.modelContext) private var modelContext
    @State private var selectedMeeting: Meeting?
    @State private var page: MainPage = .dashboard
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
                page: $page,
                searchText: $searchText
            )
            .navigationSplitViewColumnWidth(min: 215, ideal: 236, max: 320)
        } detail: {
            if page == .ask {
                AskPageView()
            } else if recordingManager.isRecording {
                LiveRecordingView()
            } else if page == .settings {
                settingsPane
            } else if page == .aiApps {
                AIAppsPageView()
            } else if page == .dashboard {
                DashboardView(selectedMeeting: $selectedMeeting, page: $page)
            } else if let meeting = selectedMeeting {
                // .id forces a fresh view identity per meeting: @State (title/name
                // drafts, audio players, tab) must not leak from one meeting to the
                // next, and onAppear/onDisappear must re-fire to stop playback.
                MeetingDetailView(meeting: meeting, onDelete: {
                    // Clear the selection first so the detail view is gone
                    // before its model object is deleted.
                    selectedMeeting = nil
                    page = .dashboard
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
                AIAppsConnectedBanner()
                if let suggestion, reviewing == nil, !recordingManager.isRecording {
                    ProfileSuggestionBanner(item: suggestion, profiles: profiles,
                                            review: { reviewing = suggestion },
                                            later: { laterIDs.insert(suggestion.id) })
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
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
        // Files the user opened, dropped or imported go straight to review.
        .onChange(of: appSession.profileReviews) { _, _ in reviewNextFile() }
        // A file that launched Parrot was queued before this view listened.
        .onAppear { reviewNextFile() }
        .sheet(item: $reviewing) { item in
            ProfileReviewView(item: item) {
                appSession.profileReviews.removeAll { $0.id == item.id }
                reviewing = nil
            }
            .environment(profileStore)
            .environment(recordingManager)
        }
        // Once, after the Profiles 2.0 migration (never on a fresh install).
        .sheet(isPresented: Binding(
            get: { profileStore.showProfiles2Screen && hasCompletedOnboarding && !recordingManager.isRecording },
            set: { profileStore.showProfiles2Screen = $0 })) {
            ProfileMigrationView()
                .environment(profileStore)
        }
        // ⌘K, the menu and "Ask about this meeting" open the Ask page.
        .onChange(of: appSession.askRequest) { _, request in
            if request != nil { page = .ask }
        }
        // A recording that starts while Ask is open shows the call screen.
        .onChange(of: recordingManager.isRecording) { _, recording in
            if recording, page == .ask { page = .dashboard }
        }
        .onReceive(NotificationCenter.default.publisher(for: .parrotMeetingWillDelete)) { note in
            guard let id = note.object as? UUID else { return }
            if selectedMeeting?.id == id {
                selectedMeeting = nil
                page = .dashboard
            }
            if appSession.selectedMeeting?.id == id { appSession.selectedMeeting = nil }
            if appSession.pendingJump?.meetingID == id { appSession.pendingJump = nil }
        }
        // Ask Parrot's citations: open that meeting (the detail view seeks).
        .onChange(of: appSession.pendingJump) { _, jump in open(jump) }
        // A window opened by a link finds the jump already waiting.
        .onAppear { open(appSession.pendingJump) }
        // openparrot:// links arrive through ParrotAppDelegate; keep them in
        // this window rather than opening a new one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onReceive(NotificationCenter.default.publisher(for: .parrotOpenAIApps)) { _ in
            page = .aiApps
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
            // AI apps' profile suggestions, ones waiting from before too.
            appSession.profileInbox.start { [appSession] in appSession.profileReviews += $0 }
            await recordingManager.prepare(modelContext: modelContext)
        }
    }

    private func reviewNextFile() {
        guard reviewing == nil else { return }
        reviewing = appSession.profileReviews.first { if case .file = $0.origin { true } else { false } }
    }

    /// Selects the meeting a jump points at; the detail view seeks.
    private func open(_ jump: AppSession.Jump?) {
        guard let jump else { return }
        let id = jump.meetingID
        let found = try? modelContext.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })).first
        guard let meeting = found else {
            appSession.pendingJump = nil
            return
        }
        selectedMeeting = meeting
        page = .meeting
    }

    private func presentBugReport() {
        reportScreenshot = BugReport.captureWindow()
        showBugReport = true
    }

    private func startImport(_ url: URL) {
        guard let meeting = recordingManager.importAudioFile(from: url, modelContext: modelContext) else { return }
        selectedMeeting = meeting
        page = .meeting
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
