import SwiftUI
import SwiftData

// MARK: - App session

/// Cross-scene state the menu bar needs: ContentView mirrors its selection here
/// so File → Export can act on the selected meeting.
@Observable @MainActor
final class AppSession {
    var selectedMeeting: Meeting?
}

extension Notification.Name {
    /// File → Import Audio… asks ContentView to present its file importer.
    static let parrotImportAudio = Notification.Name("parrotImportAudio")
    /// Edit → Find asks the sidebar to focus its search field.
    static let parrotFocusSearch = Notification.Name("parrotFocusSearch")
}

// MARK: - Shared meeting actions

/// Menu-invokable actions on a meeting, shared by the main menu, context menus,
/// and the detail toolbar. Exports write to Downloads and reveal in Finder.
@MainActor
enum MeetingActions {
    static let repoURL = "https://github.com/turantekin/Parrot"

    static func exportTXT(_ meeting: Meeting) {
        write(ExportService.exportToTXT(meeting: meeting), for: meeting, ext: "txt")
    }

    static func exportSRT(_ meeting: Meeting) {
        write(ExportService.exportToSRT(meeting: meeting), for: meeting, ext: "srt")
    }

    private static func write(_ content: String, for meeting: Meeting, ext: String) {
        let filename = meeting.title.replacingOccurrences(of: " ", with: "_")
        if let url = try? ExportService.save(content: content, filename: filename, extension: ext) {
            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    static func audioFileExists(_ meeting: Meeting) -> Bool {
        !meeting.systemAudioPath.isEmpty
            && FileManager.default.fileExists(atPath: meeting.systemAudioPath)
    }

    static func revealAudio(_ meeting: Meeting) {
        NSWorkspace.shared.selectFile(
            meeting.systemAudioPath,
            inFileViewerRootedAtPath: (meeting.systemAudioPath as NSString).deletingLastPathComponent
        )
    }

    static func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    static func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "On-device, private meeting recorder.\n\(repoURL)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        ])
    }
}

// MARK: - Main menu commands

struct ParrotCommands: Commands {
    let session: AppSession
    let recordingManager: RecordingManager
    let modelContext: ModelContext

    var body: some Commands {
        // Parrot menu: custom About + a path to the next release.
        CommandGroup(replacing: .appInfo) {
            Button("About Parrot") { MeetingActions.showAbout() }
            Button("Check for Updates…") {
                Task { @MainActor in
                    if let release = await UpdateChecker.shared.check() {
                        MeetingActions.open(release.pageURL)
                    } else {
                        NSApp.activate(ignoringOtherApps: true)
                        let alert = NSAlert()
                        alert.messageText = "You're up to date"
                        alert.informativeText = "Parrot \(UpdateChecker.currentVersion) is the newest version."
                        alert.runModal()
                    }
                }
            }
        }

        // File: the app's objects are recordings — import and export live here.
        CommandGroup(after: .newItem) {
            Button("Import Audio…") {
                NotificationCenter.default.post(name: .parrotImportAudio, object: nil)
            }
            .keyboardShortcut("o")
            .disabled(recordingManager.isRecording)

            Divider()

            Button("Export Transcript (TXT)") {
                session.selectedMeeting.map { MeetingActions.exportTXT($0) }
            }
            .keyboardShortcut("e")
            .disabled(session.selectedMeeting == nil)

            Button("Export Subtitles (SRT)") {
                session.selectedMeeting.map { MeetingActions.exportSRT($0) }
            }
            .disabled(session.selectedMeeting == nil)
        }

        // Edit: ⌘F focuses the sidebar search.
        CommandGroup(after: .textEditing) {
            Button("Find Meetings") {
                NotificationCenter.default.post(name: .parrotFocusSearch, object: nil)
            }
            .keyboardShortcut("f")
        }

        CommandMenu("Recording") {
            Button("Start Recording") {
                Task { @MainActor in
                    do {
                        // Same preflight as the menu bar / dashboard buttons.
                        try await recordingManager.preflightPermissionsAndStart(
                            modelContext: modelContext
                        )
                    } catch {
                        NSApp.activate(ignoringOtherApps: true)
                        let alert = NSAlert()
                        alert.messageText = "Couldn't start recording"
                        alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                }
            }
            .keyboardShortcut("r")
            .disabled(recordingManager.isRecording || !recordingManager.transcriptionEngine.isReady)

            Button("Stop Recording") {
                Task { @MainActor in
                    await recordingManager.stopRecording()
                }
            }
            .keyboardShortcut(".")
            .disabled(!recordingManager.isRecording || recordingManager.isStopping)
        }

        // Help: take people to the project instead of "Help isn't available".
        CommandGroup(replacing: .help) {
            Button("Parrot Help") {
                MeetingActions.open("\(MeetingActions.repoURL)#readme")
            }
            Button("Parrot on GitHub") {
                MeetingActions.open(MeetingActions.repoURL)
            }
            Button("Report an Issue…") {
                MeetingActions.open("\(MeetingActions.repoURL)/issues")
            }
        }
    }
}

// MARK: - Shared meeting context menu

/// The right-click menu every meeting row gets (sidebar + dashboard):
/// Rename / Export / Show Audio File / Delete, with its own rename alert and
/// delete confirmation so callers only supply selection cleanup.
struct MeetingContextMenu: ViewModifier {
    @Environment(RecordingManager.self) private var recordingManager
    let meeting: Meeting
    /// Runs just before deletion so callers can clear their selection.
    var onDeleted: () -> Void = {}

    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmDelete = false

    private var isLiveRecording: Bool {
        recordingManager.isRecording && recordingManager.currentMeeting?.id == meeting.id
    }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Rename…") {
                    renameText = meeting.title
                    showRename = true
                }

                Menu("Export") {
                    Button("Transcript (TXT)") { MeetingActions.exportTXT(meeting) }
                    Button("Subtitles (SRT)") { MeetingActions.exportSRT(meeting) }
                }
                .disabled(meeting.segments.isEmpty)

                Button("Show Audio File in Finder") { MeetingActions.revealAudio(meeting) }
                    .disabled(!MeetingActions.audioFileExists(meeting))

                Divider()

                Button("Delete Meeting", role: .destructive) { confirmDelete = true }
                    .disabled(isLiveRecording)
            }
            .alert("Rename Meeting", isPresented: $showRename) {
                TextField("Title", text: $renameText)
                Button("Rename") {
                    let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty { meeting.title = title }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete \"\(meeting.title)\"?",
                isPresented: $confirmDelete
            ) {
                Button("Delete", role: .destructive) {
                    onDeleted()
                    recordingManager.delete(meeting)
                }
            } message: {
                Text("The recording, transcript, and insights will be permanently removed.")
            }
    }
}

extension View {
    func meetingContextMenu(_ meeting: Meeting, onDeleted: @escaping () -> Void = {}) -> some View {
        modifier(MeetingContextMenu(meeting: meeting, onDeleted: onDeleted))
    }
}
