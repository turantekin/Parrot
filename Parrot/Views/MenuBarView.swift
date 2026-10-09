import SwiftUI
import SwiftData

/// Content of the menu-bar extra, rendered as a NATIVE menu
/// (.menuBarExtraStyle(.menu) in ParrotApp): Texts become disabled status
/// lines, Buttons menu items, Menus and Pickers submenus. Status reflects
/// the moment the menu opens — that's standard menu behavior. Kept short:
/// the call time and mute already show in the bar (MenuBarLabel).
struct MenuBarView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Environment(ProfileStore.self) private var profileStore
    @Environment(AppSession.self) private var appSession
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \CallProfile.sortOrder) private var profiles: [CallProfile]
    @Query(Self.newestFirst) private var latest: [Meeting]
    /// Follow is asked once; after that click (followed or not, X won't
    /// say) the item turns into a standing "say hi".
    @AppStorage("menuBarFollowClicked") private var followClicked = false

    private static var newestFirst: FetchDescriptor<Meeting> {
        var descriptor = FetchDescriptor<Meeting>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }

    var body: some View {
        if let prompt = recordingManager.callWatcher.prompt {
            Button(prompt.kind == .start
                   ? "Record \(prompt.appName) Call"
                   : "Call Ended? Stop Recording") {
                recordingManager.callWatcher.acceptPrompt()
            }
            Divider()
        }

        if recordingManager.isRecording {
            // Same shortcuts as the Recording menu and the global hotkeys.
            Button("Mark Moment") {
                recordingManager.markMoment()
            }
            .keyboardShortcut("m", modifiers: [.control, .option])
            .disabled(recordingManager.isStopping)

            Button(recordingManager.isMuted ? "Unmute Me" : "Mute Me") {
                recordingManager.toggleMute()
            }
            .keyboardShortcut("m", modifiers: [.control, .option, .shift])
            .disabled(recordingManager.isStopping)

            let assistant = recordingManager.callAnalysisEngine
            if assistant.isSetUp {
                Button(assistant.isPaused ? "Turn Assistant On" : "Turn Assistant Off") {
                    assistant.setPaused(!assistant.isPaused)
                }
                .disabled(recordingManager.isStopping)
            }

            Button(recordingManager.isStopping ? "Finalizing…" : "Stop Recording") {
                Task { await recordingManager.stopRecording() }
            }
            .keyboardShortcut(".")
            .disabled(recordingManager.isStopping)
        } else {
            heardSoFar
            nextCall
            if !recordingManager.transcriptionEngine.isReady {
                Text("Loading speech model…")
            }
            Button("Start Recording") { startRecording() }
                .keyboardShortcut("r")
                .disabled(!recordingManager.transcriptionEngine.isReady)
            profilePicker

            Divider()

            lastCall
            Button("Ask Parrot…") {
                showMainWindow { appSession.askRequest = AppSession.AskRequest(scope: nil, scopeTitle: nil) }
            }
            .keyboardShortcut("k")
            if followClicked {
                Button("Say Hi to Us on X 👋") { MeetingActions.open(MeetingActions.xSayHiURL) }
            } else {
                Button("Parrot Needs Friends on X 🥺") {
                    followClicked = true
                    MeetingActions.open(MeetingActions.xFollowURL)
                }
            }
        }

        Divider()

        Button("Open Parrot") { showMainWindow() }
        Button("Quit Parrot") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// A greyed header: everything Parrot has heard. Not read mid-call (that
    /// branch skips it), so the per-line saves of a live call never recount.
    @ViewBuilder private var heardSoFar: some View {
        let meetings = (try? modelContext.fetch(FetchDescriptor<Meeting>())) ?? []
        if !meetings.isEmpty {
            // Home's cached count: only meetings whose line count changed are recounted.
            let words = meetings.reduce(0) { $0 + DashboardView.words(in: $1) }
                .formatted(.number.notation(.compactName))
            let calls = meetings.count == 1 ? "1 call" : "\(meetings.count) calls"
            Text("\(words) words heard in \(calls). All ears 🦜")
            Divider()
        }
    }

    /// Today's next calendar call. Once it's about to start, one click
    /// opens its link and records it (named, and under the profile its
    /// title picks, like a detected call).
    @ViewBuilder private var nextCall: some View {
        if let next = recordingManager.callWatcher.nextCall {
            let name = next.event.title.isEmpty ? "" : " “\(Self.short(next.event.title))”"
            if next.joinable {
                Button(next.event.callLink == nil ? "Record\(name)" : "Join & Record\(name)") {
                    if let link = next.event.callLink { NSWorkspace.shared.open(link) }
                    Task { await recordingManager.startDetectedCall(appID: nil) }
                }
            } else {
                Text("Next\(name) at \(next.event.start.formatted(date: .omitted, time: .shortened))")
            }
        }
    }

    /// The profile the next recording uses: same choice as the Home chips.
    @ViewBuilder private var profilePicker: some View {
        if profiles.count > 1 {
            Picker("Profile: \(profileStore.activeProfile?.name ?? "Default")", selection: Binding(
                get: { profileStore.activeProfile?.id },
                set: { id in
                    if let profile = profiles.first(where: { $0.id == id }) { profileStore.setActive(profile) }
                }
            )) {
                ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.menu)
        }
    }

    /// The latest meeting: open its report, or copy it to paste elsewhere.
    @ViewBuilder private var lastCall: some View {
        if let meeting = latest.first {
            let length = Duration.seconds(meeting.duration)
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
            Menu("Last: \(Self.short(meeting.title)) · \(length)") {
                Button("Open Report") {
                    showMainWindow { appSession.pendingJump = AppSession.Jump(meetingID: meeting.id, time: nil) }
                }
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(meeting.summary ?? "", forType: .string)
                }
                .disabled(meeting.summary?.isEmpty ?? true)
            }
        }
    }

    private func startRecording() {
        Task {
            do {
                // Same preflight as the dashboard button — without it
                // this path silently failed when Screen Recording
                // permission was missing.
                try await recordingManager.preflightPermissionsAndStart(modelContext: modelContext)
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Couldn't start recording"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// Brings the main window forward, reopening it if it was closed.
    /// `request` runs first: an open window acts on it at once, a reopened
    /// one as it appears.
    private func showMainWindow(_ request: () -> Void = {}) {
        request()
        NSApp.activate(ignoringOtherApps: true)
        if let window = ParrotApp.mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: ParrotApp.mainWindowID)
        }
    }

    /// A menu is as wide as its longest line: a long title would stretch it.
    private static func short(_ title: String, limit: Int = 32) -> String {
        title.count > limit ? title.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…" : title
    }
}

/// The menu-bar icon: the parrot, and while recording a dot, the call time
/// and a crossed-out mic when muted. Drawn into one template image, so the
/// bar shows exactly this layout and macOS tints it for light, dark and the
/// open menu.
struct MenuBarLabel: View {
    let recordingManager: RecordingManager

    var body: some View {
        let time = recordingManager.isRecording ? recordingManager.formattedElapsedTime : nil
        let muted = recordingManager.isRecording && recordingManager.isMuted
        Image(nsImage: Self.render(time: time, muted: muted))
            .accessibilityLabel(time.map { "Parrot, recording \($0)\(muted ? ", muted" : "")" } ?? "Parrot")
    }

    static func render(time: String?, muted: Bool) -> NSImage {
        let parrot = NSImage(named: "MenuBarIcon").map(Image.init(nsImage:)) ?? Image(systemName: "waveform")
        let content = HStack(spacing: Theme.Metrics.menuBarGap) {
            parrot
            if let time {
                Circle().frame(width: Theme.Metrics.menuBarDot, height: Theme.Metrics.menuBarDot)
                Text(time)
            }
            if muted { Image(systemName: "mic.slash.fill") }
        }
        .font(Theme.Typography.menuBarTime)
        .foregroundStyle(.black)   // only the shape counts: the image is a template
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}
