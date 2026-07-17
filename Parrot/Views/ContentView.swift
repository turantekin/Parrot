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
    private let updateChecker = UpdateChecker.shared

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
                if let release = updateChecker.available, !recordingManager.isRecording {
                    UpdateBanner(release: release)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, 12)
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
            updateChecker.checkIfDue()
            guard !hasLoadedModel else { return }
            hasLoadedModel = true
            await recordingManager.prepare(modelContext: modelContext)
        }
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

/// "A newer Parrot exists" — one line, one Download click, dismissible.
/// Hidden during recording; the update will still be there after the call.
private struct UpdateBanner: View {
    let release: UpdateChecker.Release

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Theme.Colors.accent)
            Text("Parrot \(release.version) is available")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink)
            Button("Download") {
                MeetingActions.open(release.dmgURL ?? release.pageURL)
            }
            .controlSize(.small)
            Button("What's New") {
                MeetingActions.open(release.pageURL)
            }
            .buttonStyle(.link)
            .font(Theme.Typography.secondary)
            Button {
                UpdateChecker.shared.skipAvailable()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Colors.ink3)
            }
            .buttonStyle(.plain)
            .help("Skip this version")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
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
